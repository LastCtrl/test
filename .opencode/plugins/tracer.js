// tracer.js - opencode distributed tracing plugin (v2.1, tasks P1-4 + P3-3 gap).
//
// RUNTIME: loaded by opencode (ESM). Must NEVER break the host: every hook body
// is guarded and every failure is logged instead of being swallowed.
//
// v2 is ADDITIVE over the existing traces.jsonl (legacy keys ts/type/tool/ms/id
// are preserved), it only appends correlation fields:
//   session_id, message_id, call_id, agent, agent_source, task_id, attempt_id,
//   duration_ms, status, error
//
// v2.1 (2026-09-17, follow-up of the P3-3 acceptance) closes the AGENT gap that
// was measured on opencode 1.18.31 with a temporary hook probe:
//   * `chat.message` input carries ONLY { sessionID, model } - no `agent` and no
//     `messageID`; the message id is taken from output.message.id instead;
//   * `tool.execute.before/after` carry ONLY { tool, sessionID, callID };
//   * the runtime agent is exposed by the `event` hook: session.updated =>
//     properties.info.agent (session.created does not have it yet);
//   * the fleet agent identity is exported by the launcher (inbox-engine.ps1)
//     as AGENT_HQ_AGENT, next to AGENT_HQ_TASK_ID / AGENT_HQ_ATTEMPT_ID; it wins
//     over the runtime value because every fleet agent is mode=subagent and
//     `opencode run --agent <subagent>` falls back to the default primary agent;
//   * `chat.params` also carries an `agent`, but the first request of a session
//     is the internal "title" helper agent - using it would mis-attribute the
//     session, so it is deliberately ignored;
//   * a `session_agent` binding record is emitted when the agent is learned
//     AFTER session_start (so consumers can still join the session), plus one
//     bounded `plugin_diag` record per session listing which hooks actually
//     delivered which correlation data.
//
// Error handling: nothing is ever silently swallowed - every catch block
// reports through logError() (see below) and the host keeps running.
// A failure is appended to <tracesDir>/errors.jsonl; if even that write fails,
// a bounded console.warn is emitted as the last resort.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const DEFAULT_SUBDIR = "agent-hq-traces";
const MAX_TRACKED_CALLS = 1000;
const MAX_TRACKED_SESSIONS = 200;
const MAX_WARNINGS = 20;
const MAX_ERROR_TEXT = 300;
const MAX_STACK_LINES = 6;

// Higher rank wins when two sources describe the same session (see v2.1 notes).
const AGENT_SOURCE_RANK = { env: 3, "session.updated": 2, "chat.message": 1 };

// Traces directory. Precedence: explicit argument (tests) > AGENT_HQ_TRACES_DIR
// (isolated runs) > legacy %LOCALAPPDATA%\opencode\agent-hq-traces location.
export const resolveTracesDir = (override) => {
  if (override) return override;
  if (process.env.AGENT_HQ_TRACES_DIR) return process.env.AGENT_HQ_TRACES_DIR;
  return path.join(
    process.env.LOCALAPPDATA || process.env.APPDATA || os.tmpdir(),
    "opencode",
    DEFAULT_SUBDIR
  );
};

// Correlation ids of the current run. The inbox engine does not export them yet
// (AGENT_HQ_TASK_ID / AGENT_HQ_ATTEMPT_ID); when they are absent the fields are
// empty strings so the trace stays joinable on session_id / call_id.
export const correlationIds = (env = process.env) => ({
  task_id: env.AGENT_HQ_TASK_ID || "",
  attempt_id: env.AGENT_HQ_ATTEMPT_ID || "",
});

const safeString = (value) => {
  try {
    return value === null || value === undefined ? "" : String(value);
  } catch (_err) {
    return "";
  }
};

// Defensive read: a hostile/odd input object must not turn a log line into a crash.
const safeField = (obj, key) => {
  try {
    return obj === null || obj === undefined ? undefined : obj[key];
  } catch (_err) {
    return undefined;
  }
};

// Fleet agent identity exported by the launcher (inbox-engine.ps1). Explicit
// launcher data, never a guess: empty string when the plugin is not launched by
// the engine (interactive use).
export const envAgent = (env = process.env) => safeString(safeField(env, "AGENT_HQ_AGENT")).trim();

const describeError = (err) => {
  const message = safeString(safeField(err, "message") || err);
  return message.slice(0, MAX_ERROR_TEXT) || "unknown error";
};

const shrinkStack = (err) => {
  const stack = safeString(safeField(err, "stack"));
  return stack ? stack.split("\n").slice(0, MAX_STACK_LINES).join("\n") : "";
};

// Derive a fact-based status from the tool output metadata (never from prose).
export const deriveToolStatus = (output) => {
  const metadata = safeField(output, "metadata");
  const exit =
    typeof safeField(metadata, "exit") === "number"
      ? safeField(metadata, "exit")
      : safeField(metadata, "exitCode");
  if (typeof exit === "number" && Number.isFinite(exit)) {
    return exit === 0
      ? { status: "ok", error: null }
      : { status: `exit:${exit}`, error: null };
  }
  const errorText = safeField(metadata, "error");
  if (typeof errorText === "string" && errorText) {
    return { status: "error", error: errorText.slice(0, 200) };
  }
  return { status: "ok", error: null };
};

export const TracerPlugin = ({ directory: _directory, tracesDir, now } = {}) => {
  const targetDir = resolveTracesDir(tracesDir);
  const tracesFile = path.join(targetDir, "traces.jsonl");
  const errorsFile = path.join(targetDir, "errors.jsonl");
  // Injectable clock: production uses Date.now, tests inject a deterministic one.
  const clock = typeof now === "function" ? now : () => Date.now();

  // callID -> { startedAt, tool, session_id, agent, agent_source }
  const starts = new Map();
  // sessionID -> { agent, agent_source, message_id }.
  const sessionMeta = new Map();
  // sessionID -> startedAt, used for the session duration.
  const sessionStarts = new Map();
  // sessionID -> correlation delivery counters, summarised once per session in a
  // single plugin_diag record (bounded: one record per session, never per hook).
  const sessionCounts = new Map();

  let warnings = 0;
  let lastConsoleError = "";
  const warn = (text) => {
    if (warnings >= MAX_WARNINGS) return;
    warnings += 1;
    try {
      console.warn(`[tracer] ${text}`);
    } catch (consoleError) {
      // The console is gone as well: keep the host alive and keep the reason
      // in memory instead of throwing or swallowing it invisibly.
      lastConsoleError = describeError(consoleError);
    }
  };

  const ensureDir = () => {
    fs.mkdirSync(targetDir, { recursive: true });
  };

  // Last-resort sink: errors.jsonl. Never throws, never silent.
  const logError = (hook, err, context = {}) => {
    const entry = {
      ts: new Date().toISOString(),
      type: "plugin_error",
      plugin: "tracer",
      hook,
      message: describeError(err),
      code: safeString(safeField(err, "code")),
      stack: shrinkStack(err),
    };
    for (const [key, value] of Object.entries(context)) {
      entry[key] = safeString(value);
    }
    try {
      ensureDir();
      fs.appendFileSync(errorsFile, JSON.stringify(entry) + "\n", "utf-8");
    } catch (logErr) {
      warn(
        `errors.jsonl write failed (${describeError(logErr)}); original ${hook} error: ${describeError(err)}`
      );
    }
  };

  const writeTrace = (hook, record, context = {}) => {
    try {
      ensureDir();
      fs.appendFileSync(tracesFile, JSON.stringify(record) + "\n", "utf-8");
    } catch (err) {
      logError(hook, err, { stage: "write_traces", ...context });
    }
  };

  const cacheSessionMeta = (sessionID, patch) => {
    const previous = sessionMeta.get(sessionID) || {};
    if (sessionMeta.size >= MAX_TRACKED_SESSIONS && !sessionMeta.has(sessionID)) {
      sessionMeta.delete(sessionMeta.keys().next().value);
    }
    const previousAgent = safeString(previous.agent);
    const previousSource = safeString(previous.agent_source);
    const candidate = safeString(patch.agent);
    const candidateSource = safeString(patch.agent_source);
    const candidateWins =
      Boolean(candidate) &&
      (!previousAgent || (AGENT_SOURCE_RANK[candidateSource] || 0) > (AGENT_SOURCE_RANK[previousSource] || 0));
    sessionMeta.set(sessionID, {
      agent: candidateWins ? candidate : previousAgent,
      agent_source: candidateWins ? candidateSource : previousSource,
      message_id: safeString(patch.message_id) || safeString(previous.message_id),
      // What the RUNTIME reported, even when a stronger source (launcher env)
      // wins the effective agent - kept for the plugin_diag record.
      runtime_agent: safeString(patch.runtime_agent) || safeString(previous.runtime_agent),
    });
  };

  const bumpSessionCounter = (sessionID, key) => {
    if (!sessionID) return;
    let entry = sessionCounts.get(sessionID);
    if (!entry) {
      if (sessionCounts.size >= MAX_TRACKED_SESSIONS && !sessionCounts.has(sessionID)) {
        sessionCounts.delete(sessionCounts.keys().next().value);
      }
      entry = { chat_message: 0, session_updated_agent: 0, tool_spans: 0 };
      sessionCounts.set(sessionID, entry);
    }
    entry[key] = (entry[key] || 0) + 1;
  };

  // Bind an agent to a session. When the binding is learned after session_start
  // was already written (the normal case: session.created has no agent), one
  // additive `session_agent` record is emitted so the session stays joinable.
  // A stronger source already in place is never overwritten (see RANK).
  const rememberAgent = (sessionID, agent, source, ids, runtimeAgent = "") => {
    if (!sessionID || !agent) return "";
    const before = sessionMeta.get(sessionID) || {};
    cacheSessionMeta(sessionID, { agent, agent_source: source, runtime_agent: runtimeAgent });
    const after = sessionMeta.get(sessionID) || {};
    if (after.agent !== agent) {
      // A stronger source (usually the launcher env) pinned a different agent:
      // keep it and report the disagreement through plugin_diag (agent_mismatch).
      return after.agent || "";
    }
    if (before.agent === agent) return after.agent;
    writeTrace(
      "event",
      {
        ts: new Date().toISOString(),
        type: "session_agent",
        id: sessionID, // legacy key, mirrors session_start
        session_id: sessionID,
        agent,
        agent_source: after.agent_source || source,
        task_id: ids.task_id,
        attempt_id: ids.attempt_id,
      },
      { session_id: sessionID }
    );
    return after.agent;
  };

  return {
    "tool.execute.before": async (input, _output) => {
      try {
        const callID = safeField(input, "callID");
        if (!callID) return;
        if (starts.size >= MAX_TRACKED_CALLS) {
          starts.delete(starts.keys().next().value);
        }
        const sessionID = safeString(safeField(input, "sessionID"));
        const meta = sessionMeta.get(sessionID) || {};
        starts.set(callID, {
          startedAt: clock(),
          tool: safeString(safeField(input, "tool")),
          session_id: sessionID,
          agent: meta.agent || "",
          agent_source: meta.agent_source || "",
        });
      } catch (err) {
        logError("tool.execute.before", err, {
          tool: safeString(safeField(input, "tool")),
        });
      }
    },

    "tool.execute.after": async (input, output) => {
      const callID = safeField(input, "callID");
      try {
        const tool = safeString(safeField(input, "tool"));
        const sessionID = safeString(safeField(input, "sessionID"));
        const start = callID ? starts.get(callID) : undefined;
        if (callID) starts.delete(callID);
        const duration_ms = start ? Math.max(0, clock() - start.startedAt) : 0;
        const meta = sessionMeta.get(sessionID) || {};
        const { status, error } = deriveToolStatus(output);
        const ids = correlationIds();
        bumpSessionCounter(sessionID, "tool_spans");
        writeTrace(
          "tool.execute.after",
          {
            ts: new Date().toISOString(),
            type: "tool",
            tool, // legacy key
            ms: duration_ms, // legacy key
            duration_ms,
            status,
            error,
            session_id: sessionID,
            message_id: meta.message_id || "",
            call_id: safeString(callID),
            agent: meta.agent || (start ? start.agent : ""),
            agent_source: meta.agent_source || (start ? start.agent_source : ""),
            task_id: ids.task_id,
            attempt_id: ids.attempt_id,
          },
          { tool, session_id: sessionID }
        );
      } catch (err) {
        logError("tool.execute.after", err, {
          call_id: safeString(callID),
          tool: safeString(safeField(input, "tool")),
        });
      }
    },

    // First hook of a session. On opencode 1.18.31 its input carries ONLY
    // { sessionID, model }: `agent` and `messageID` are absent (measured with a
    // hook probe, 2026-09-17), so the agent comes from the launcher env or from
    // session.updated, and the message id from output.message.id. Both fallbacks
    // are optional - when nothing carries the value, the field stays empty
    // instead of being guessed.
    "chat.message": async (input, output) => {
      try {
        const sessionID = safeString(safeField(input, "sessionID"));
        if (!sessionID) return;
        bumpSessionCounter(sessionID, "chat_message");
        const runtimeAgent = safeString(safeField(input, "agent"));
        const launcherAgent = envAgent();
        const message = safeField(output, "message");
        cacheSessionMeta(sessionID, {
          agent: launcherAgent || runtimeAgent,
          agent_source: launcherAgent ? "env" : runtimeAgent ? "chat.message" : "",
          runtime_agent: runtimeAgent,
          message_id:
            safeString(safeField(input, "messageID")) || safeString(safeField(message, "id")),
        });
      } catch (err) {
        logError("chat.message", err, {});
      }
    },

    event: async ({ event } = {}) => {
      let eventType = "";
      try {
        eventType = safeString(safeField(event, "type"));
        const props = safeField(event, "properties") || {};
        // session.created carries properties.info.id, session.idle/error carry
        // properties.sessionID (see @opencode-ai/sdk types.gen.d.ts).
        const sessionID =
          safeString(safeField(props, "sessionID")) ||
          safeString(safeField(safeField(props, "info"), "id"));
        if (!sessionID) return;
        const ids = correlationIds();

        // Agent of the session, strongest source first: launcher env, then the
        // runtime (session.updated => info.agent; session.created has no agent
        // yet). Empty when neither is available - the field is never guessed.
        const runtimeAgent = safeString(safeField(safeField(props, "info"), "agent"));
        const launcherAgent = envAgent();
        const reportedAgent = launcherAgent || runtimeAgent;
        if (runtimeAgent) bumpSessionCounter(sessionID, "session_updated_agent");
        if (reportedAgent) {
          rememberAgent(
            sessionID,
            reportedAgent,
            launcherAgent ? "env" : "session.updated",
            ids,
            runtimeAgent
          );
        }

        const meta = sessionMeta.get(sessionID) || {};

        if (eventType === "session.created") {
          sessionStarts.set(sessionID, clock());
          writeTrace(
            "event",
            {
              ts: new Date().toISOString(),
              type: "session_start",
              id: sessionID, // legacy key
              session_id: sessionID,
              agent: meta.agent || "",
              agent_source: meta.agent_source || "",
              task_id: ids.task_id,
              attempt_id: ids.attempt_id,
            },
            { session_id: sessionID }
          );
        } else if (eventType === "session.error") {
          const errorObject = safeField(props, "error") || {};
          const msg =
            safeField(errorObject, "message") ??
            safeField(errorObject, "name") ??
            safeField(errorObject, "data") ??
            props;
          let raw = "";
          try {
            raw = JSON.stringify(props, null, 0);
          } catch (serializeErr) {
            raw = "[unserializable]";
            logError("event", serializeErr, {
              stage: "serialize_props",
              session_id: sessionID,
            });
          }
          writeTrace(
            "event",
            {
              ts: new Date().toISOString(),
              type: "error",
              id: sessionID, // legacy key
              session_id: sessionID,
              agent: meta.agent || "",
              agent_source: meta.agent_source || "",
              message: safeString(msg).slice(0, MAX_ERROR_TEXT),
              props: safeString(raw).slice(0, 500),
              task_id: ids.task_id,
              attempt_id: ids.attempt_id,
            },
            { session_id: sessionID }
          );
        } else if (eventType === "session.idle") {
          const startedAt = sessionStarts.get(sessionID);
          const duration_ms = startedAt ? Math.max(0, clock() - startedAt) : 0;
          sessionStarts.delete(sessionID);
          writeTrace(
            "event",
            {
              ts: new Date().toISOString(),
              type: "session_end",
              id: sessionID, // legacy key
              session_id: sessionID,
              agent: meta.agent || "",
              agent_source: meta.agent_source || "",
              duration_ms,
              task_id: ids.task_id,
              attempt_id: ids.attempt_id,
            },
            { session_id: sessionID }
          );
          // One bounded diagnostic per session: which hooks really delivered the
          // correlation data, and whether the launcher and the runtime agree on
          // the agent. Keeps the next investigation from guessing.
          const counters = sessionCounts.get(sessionID) || {};
          sessionCounts.delete(sessionID);
          writeTrace(
            "event",
            {
              ts: new Date().toISOString(),
              type: "plugin_diag",
              id: sessionID, // legacy key
              session_id: sessionID,
              agent: meta.agent || "",
              agent_source: meta.agent_source || "",
              runtime_agent: meta.runtime_agent || "",
              chat_message: counters.chat_message || 0,
              session_updated_agent: counters.session_updated_agent || 0,
              tool_spans: counters.tool_spans || 0,
              // 1 = the launcher and the runtime disagree on who ran the session.
              agent_mismatch:
                meta.runtime_agent && meta.agent && meta.runtime_agent !== meta.agent ? 1 : 0,
              task_id: ids.task_id,
              attempt_id: ids.attempt_id,
            },
            { session_id: sessionID }
          );
        }
      } catch (err) {
        logError("event", err, { event_type: eventType });
      }
    },
  };
};
