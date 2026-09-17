// tracer.js - opencode distributed tracing plugin (v2, task P1-4).
//
// RUNTIME: loaded by opencode (ESM). Must NEVER break the host: every hook body
// is guarded and every failure is logged instead of being swallowed.
//
// v2 is ADDITIVE over the existing traces.jsonl (legacy keys ts/type/tool/ms/id
// are preserved), it only appends correlation fields:
//   session_id, message_id, call_id, agent, task_id, attempt_id,
//   duration_ms, status, error
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

  // callID -> { startedAt, tool, session_id, agent }
  const starts = new Map();
  // sessionID -> { agent, message_id } (filled from chat.message, which is the
  // only hook exposing agent/messageID; tool hooks do not carry them).
  const sessionMeta = new Map();
  // sessionID -> startedAt, used for the session duration.
  const sessionStarts = new Map();

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
    sessionMeta.set(sessionID, {
      agent: patch.agent || previous.agent || "",
      message_id: patch.message_id || previous.message_id || "",
    });
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

    // chat.message is the only hook that exposes agent + messageID.
    "chat.message": async (input, _output) => {
      try {
        const sessionID = safeString(safeField(input, "sessionID"));
        if (!sessionID) return;
        cacheSessionMeta(sessionID, {
          agent: safeString(safeField(input, "agent")),
          message_id: safeString(safeField(input, "messageID")),
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
        const meta = sessionMeta.get(sessionID) || {};
        const ids = correlationIds();

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
              duration_ms,
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
