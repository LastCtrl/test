// scoring.js - opencode performance scoring plugin (v2, task P1-4).
//
// RUNTIME: loaded by opencode (ESM). Must NEVER break the host: every hook body
// is guarded and every failure is logged instead of being swallowed.
//
// v2 is ADDITIVE over the existing performance.jsonl (legacy keys ts /
// session_id / duration_ms / score are preserved) and adds a CORRELATION layer:
//   * traces             (session_id / call_id / task_id / attempt_id)
//   * machine evidence   (.memory/evidence/<task_id>.json, written by the poller
//                          runtime - exit codes, statuses, durations, hashes)
//   * self-report        (CONTEXT-BUFFER.md "STATUS: resolved" claims)
//
// The score is derived from FACTS (exit_code / attempts / presence of evidence),
// never from the agent's prose. The pure helpers below are exported so tests can
// drive them with fixtures.
//
// Error handling: nothing is ever silently swallowed - every catch block
// reports through logError() (see below) and the host keeps running.
// A failure is appended to <tracesDir>/errors.jsonl; if even that write fails,
// a bounded console.warn is emitted as the last resort.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const DEFAULT_SUBDIR = "agent-hq-traces";
const MAX_TRACKED_SESSIONS = 200;
const MAX_WARNINGS = 20;
const MAX_ERROR_TEXT = 300;
const MAX_STACK_LINES = 6;
const EVIDENCE_DIR_NAME = "evidence";
const CONTEXT_BUFFER_FILE = "CONTEXT-BUFFER.md";
// Traces are read tail-first: the live traces.jsonl is already ~1.5 MB.
const MAX_TAIL_BYTES = 512 * 1024;

// exit_code/status values that count as a machine-verified failure.
const FAILED_STATUSES = new Set(["error", "failed", "failure", "timeout", "blocked"]);
// Self-report statuses that claim success.
const CLAIMED_RESOLVED = new Set(["resolved", "done", "completed", "pass", "passed"]);

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

// <repo root>/.memory/evidence - same layout the poller runtime writes.
export const resolveEvidenceDir = (directory, override) => {
  if (override) return override;
  const root = directory || process.cwd();
  return path.join(root, ".memory", EVIDENCE_DIR_NAME);
};

export const resolveContextBufferPath = (directory, override) => {
  if (override) return override;
  return path.join(directory || process.cwd(), CONTEXT_BUFFER_FILE);
};

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

// ---------------------------------------------------------------------------
// Machine evidence (facts)
// ---------------------------------------------------------------------------

// Read every .memory/evidence/*.json document. Deterministic order (sorted by
// file name). A broken document is reported, not silently skipped.
export const readEvidenceDir = (evidenceDir) => {
  const records = [];
  const errors = [];
  let names = [];
  try {
    names = fs.readdirSync(evidenceDir);
  } catch (err) {
    if (safeString(safeField(err, "code")) !== "ENOENT") {
      errors.push({ file: evidenceDir, message: describeError(err) });
    }
    return { records, errors };
  }
  for (const name of names.filter((n) => n.endsWith(".json")).sort()) {
    const file = path.join(evidenceDir, name);
    try {
      const raw = fs.readFileSync(file, "utf-8");
      const doc = JSON.parse(raw);
      records.push({
        task_id: safeString(safeField(doc, "task_id")) || name.replace(/\.json$/, ""),
        attempts: Array.isArray(safeField(doc, "attempts")) ? safeField(doc, "attempts") : [],
        file,
      });
    } catch (err) {
      errors.push({ file: name, message: describeError(err) });
    }
  }
  return { records, errors };
};

// Reduce evidence documents to per-task facts.
export const aggregateEvidence = (records) => {
  const byTask = new Map();
  for (const record of records || []) {
    const taskId = safeString(safeField(record, "task_id"));
    if (!taskId) continue;
    const attempts = Array.isArray(safeField(record, "attempts")) ? safeField(record, "attempts") : [];
    if (!byTask.has(taskId)) {
      byTask.set(taskId, {
        task_id: taskId,
        attempts: 0,
        failed: 0,
        succeeded: 0,
        exit_codes: [],
        statuses: [],
        agents: [],
        duration_ms_total: 0,
        evidence_file: safeString(safeField(record, "file")),
      });
    }
    const entry = byTask.get(taskId);
    for (const attempt of attempts) {
      entry.attempts += 1;
      const exitCode = safeField(attempt, "exit_code");
      const status = safeString(safeField(attempt, "status"));
      const durationMs = safeField(attempt, "duration_ms");
      const agent = safeString(safeField(attempt, "agent"));
      const numericExit = typeof exitCode === "number" && Number.isFinite(exitCode) ? exitCode : null;
      const isFailure = (numericExit !== null && numericExit !== 0) || FAILED_STATUSES.has(status);
      if (isFailure) entry.failed += 1;
      else entry.succeeded += 1;
      entry.exit_codes.push(numericExit);
      entry.statuses.push(status);
      entry.duration_ms_total += typeof durationMs === "number" && Number.isFinite(durationMs) ? durationMs : 0;
      if (agent && !entry.agents.includes(agent)) entry.agents.push(agent);
    }
  }
  return [...byTask.values()].sort((a, b) => a.task_id.localeCompare(b.task_id));
};

// Fact-based score: every failed attempt costs 25 points, every retry 10.
export const computeTaskScore = (aggregate = {}) => {
  const attempts = Number.isInteger(safeField(aggregate, "attempts")) ? safeField(aggregate, "attempts") : 0;
  const failed = Number.isInteger(safeField(aggregate, "failed")) ? safeField(aggregate, "failed") : 0;
  const retries = Math.max(0, attempts - 1);
  const score = Math.max(0, Math.min(100, 100 - 25 * failed - 10 * retries));
  let verdict = "warn";
  if (attempts === 0) verdict = "no_evidence";
  else if (failed >= attempts) verdict = "fail";
  else if (failed === 0) verdict = "pass";
  return { score, verdict, attempts, failed, retries, formula: "100 - 25*failed - 10*(attempts-1)" };
};

// ---------------------------------------------------------------------------
// Self-report (claims) correlation
// ---------------------------------------------------------------------------

// Parse CONTEXT-BUFFER.md agent entries: header line "[TIME] agent -> team-lead:"
// followed by TYPE/STATUS/CONTENT fields. Claims are only compared with facts,
// they never feed the score directly.
export const parseSelfReports = (text) => {
  const reports = [];
  const lines = safeString(text).split(/\r?\n/);
  const header = /^\[[^\]]*\]\s+([\w.\-]+)\s*(?:->|→|-->)\s*([\w.\-]+)\s*:\s*$/;
  let current = null;
  for (const rawLine of lines) {
    const line = rawLine.trim();
    const match = header.exec(line);
    if (match) {
      if (current) reports.push(current);
      current = { agent: match[1], to: match[2], type: "", status: "", task_ids: [], tags: [] };
      continue;
    }
    if (!current) continue;
    const typeMatch = /^TYPE:\s*([A-Za-z_\-]+)/.exec(line);
    if (typeMatch && !current.type) current.type = typeMatch[1].toLowerCase();
    const statusMatch = /^STATUS:\s*([A-Za-z_\-]+)/.exec(line);
    if (statusMatch && !current.status) current.status = statusMatch[1].toLowerCase();
    // Correlation keys a self-report can carry: an explicit task_id field, an
    // evidence path mention, a P1-4 style tag or a task-/msg-/attempt- token.
    for (const idMatch of line.matchAll(/task[_\- ]?id\s*[:=]\s*([A-Za-z0-9._\-]+)/gi)) {
      if (!current.task_ids.includes(idMatch[1])) current.task_ids.push(idMatch[1]);
    }
    for (const pathMatch of line.matchAll(/\.memory[\\/]evidence[\\/]([A-Za-z0-9._\-]+)\.json/gi)) {
      if (!current.task_ids.includes(pathMatch[1])) current.task_ids.push(pathMatch[1]);
    }
    for (const tokenMatch of line.matchAll(/\b((?:task|msg|attempt|session)[-_][A-Za-z0-9._-]+)\b/gi)) {
      if (!current.task_ids.includes(tokenMatch[1])) current.task_ids.push(tokenMatch[1]);
    }
    for (const tagMatch of line.matchAll(/\b([A-Z]{1,3}-\d+(?:-\d+)?)\b/g)) {
      if (!current.tags.includes(tagMatch[1])) current.tags.push(tagMatch[1]);
    }
  }
  if (current) reports.push(current);
  return reports;
};

// Join facts with claims. `false_done` = the agent claimed success while the
// machine evidence proves at least one failure; `unverified` = the claim has no
// evidence behind it at all.
export const correlateSelfReports = (aggregates, reports) => {
  const claims = new Map();
  for (const report of reports || []) {
    const status = safeString(safeField(report, "status"));
    const claimed = CLAIMED_RESOLVED.has(status) ? "resolved" : status;
    for (const key of [...(safeField(report, "task_ids") || []), ...(safeField(report, "tags") || [])]) {
      if (!claims.has(key)) claims.set(key, { agent: safeString(safeField(report, "agent")), claimed_status: claimed });
    }
  }
  return (aggregates || []).map((aggregate) => {
    const claim = claims.get(aggregate.task_id);
    const merged = { ...aggregate };
    merged.claimed_status = claim ? claim.claimed_status : "";
    merged.claimed_by = claim ? claim.agent : "";
    merged.false_done = Boolean(claim) && claim.claimed_status === "resolved" && aggregate.failed > 0;
    merged.unverified = Boolean(claim) && claim.claimed_status === "resolved" && aggregate.attempts === 0;
    return merged;
  });
};

// ---------------------------------------------------------------------------
// Traces correlation (spans written by tracer.js) + machine evidence (facts)
// ---------------------------------------------------------------------------

// Read traces.jsonl. Only the tail is parsed (the file grows unbounded: the live
// one is ~1.5 MB / 20k lines) so the cost stays constant; `truncated` tells the
// caller that older spans were not looked at. A partial first line after a tail
// read is dropped. Broken lines are reported, never silently skipped.
export const readTracesDir = (tracesDir, options = {}) => {
  const maxBytes = Number.isInteger(safeField(options, "maxBytes")) && safeField(options, "maxBytes") > 0
    ? safeField(options, "maxBytes")
    : MAX_TAIL_BYTES;
  const file = path.join(tracesDir, "traces.jsonl");
  const records = [];
  const errors = [];
  let stat = null;
  try {
    stat = fs.statSync(file);
  } catch (err) {
    if (safeString(safeField(err, "code")) !== "ENOENT") {
      errors.push({ file, message: describeError(err) });
    }
    return { records, errors, file, truncated: false };
  }
  const truncated = stat.size > maxBytes;
  let text = "";
  try {
    if (!truncated) {
      text = fs.readFileSync(file, "utf-8");
    } else {
      const handle = fs.openSync(file, "r");
      try {
        const buffer = Buffer.alloc(maxBytes);
        const read = fs.readSync(handle, buffer, 0, maxBytes, stat.size - maxBytes);
        text = buffer.subarray(0, read).toString("utf-8");
      } finally {
        fs.closeSync(handle);
      }
    }
  } catch (err) {
    errors.push({ file, message: describeError(err) });
    return { records, errors, file, truncated };
  }
  const lines = text.split(/\r?\n/);
  // A tail read starts mid-line: drop that partial first line.
  if (truncated && lines.length > 0) lines.shift();
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    try {
      records.push(JSON.parse(line));
    } catch (err) {
      errors.push({ file, message: describeError(err) });
    }
  }
  return { records, errors, file, truncated };
};

// Per-session span summary. Only `tool` spans carry a duration and a status.
export const summarizeTraces = (records) => {
  const bySession = new Map();
  for (const record of records || []) {
    if (safeString(safeField(record, "type")) !== "tool") continue;
    const sessionId = safeString(safeField(record, "session_id")) || "(unknown)";
    if (!bySession.has(sessionId)) {
      bySession.set(sessionId, {
        session_id: sessionId,
        tool_spans: 0,
        tool_failures: 0,
        duration_ms_total: 0,
        agents: [],
        task_id: "",
      });
    }
    const entry = bySession.get(sessionId);
    entry.tool_spans += 1;
    if (safeString(safeField(record, "status")) !== "ok") entry.tool_failures += 1;
    const duration = safeField(record, "duration_ms");
    entry.duration_ms_total += typeof duration === "number" && Number.isFinite(duration) ? duration : 0;
    const agent = safeString(safeField(record, "agent"));
    if (agent && !entry.agents.includes(agent)) entry.agents.push(agent);
    if (!entry.task_id) entry.task_id = safeString(safeField(record, "task_id"));
  }
  return [...bySession.values()].sort((a, b) => a.session_id.localeCompare(b.session_id));
};

// Join the trace summaries with the evidence aggregates on task_id.
export const correlateTracesWithEvidence = (summaries, aggregates) => {
  const byTask = new Map();
  for (const summary of summaries || []) {
    const taskId = safeString(safeField(summary, "task_id"));
    if (!taskId) continue;
    const existing = byTask.get(taskId);
    if (!existing) {
      byTask.set(taskId, { ...summary });
      continue;
    }
    existing.tool_spans += summary.tool_spans;
    existing.tool_failures += summary.tool_failures;
    existing.duration_ms_total += summary.duration_ms_total;
    for (const agent of summary.agents) {
      if (!existing.agents.includes(agent)) existing.agents.push(agent);
    }
  }
  return (aggregates || []).map((aggregate) => {
    const trace = byTask.get(aggregate.task_id) || null;
    return {
      ...aggregate,
      traces: trace,
      trace_tool_spans: trace ? trace.tool_spans : 0,
      trace_tool_failures: trace ? trace.tool_failures : 0,
    };
  });
};

// One-shot helper: facts + traces + claims for a whole repository root.
export const collectScoringFacts = ({ directory, evidenceDir, contextBufferPath, tracesDir } = {}) => {
  const evidence = readEvidenceDir(resolveEvidenceDir(directory, evidenceDir));
  const aggregates = aggregateEvidence(evidence.records);
  let markdown = "";
  const bufferPath = resolveContextBufferPath(directory, contextBufferPath);
  try {
    markdown = fs.existsSync(bufferPath) ? fs.readFileSync(bufferPath, "utf-8") : "";
  } catch (err) {
    evidence.errors.push({ file: bufferPath, message: describeError(err) });
  }
  const traces = readTracesDir(resolveTracesDir(tracesDir));
  const reports = parseSelfReports(markdown);
  const correlated = correlateSelfReports(aggregates, reports);
  return {
    aggregates: correlateTracesWithEvidence(summarizeTraces(traces.records), correlated),
    reports,
    traces: { count: traces.records.length, truncated: traces.truncated, file: traces.file },
    errors: [...evidence.errors, ...traces.errors],
  };
};

// Legacy session score (duration based) + additive fact-based fields.
export const buildSessionRecord = ({ sessionID, duration_ms, ts, task_id = "", aggregate = null, trace = null }) => {
  const record = {
    ts,
    session_id: sessionID, // legacy key
    duration_ms, // legacy key
    score: Math.max(0, 100 - Math.round(duration_ms / 60000)), // legacy key
    type: "session",
    task_id,
    trace_tool_spans: trace ? trace.tool_spans : 0,
    trace_tool_failures: trace ? trace.tool_failures : 0,
  };
  if (aggregate) {
    const facts = computeTaskScore(aggregate);
    record.attempts = aggregate.attempts;
    record.failed = aggregate.failed;
    record.exit_codes = aggregate.exit_codes;
    record.fact_score = facts.score;
    record.verdict = facts.verdict;
  }
  return record;
};

export const ScoringPlugin = ({ directory, tracesDir, evidenceDir, contextBufferPath, now } = {}) => {
  const targetDir = resolveTracesDir(tracesDir);
  const perfFile = path.join(targetDir, "performance.jsonl");
  const errorsFile = path.join(targetDir, "errors.jsonl");
  const clock = typeof now === "function" ? now : () => Date.now();
  const sessions = new Map();

  let warnings = 0;
  let lastConsoleError = "";
  const warn = (text) => {
    if (warnings >= MAX_WARNINGS) return;
    warnings += 1;
    try {
      console.warn(`[scoring] ${text}`);
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
      ts: new Date(clock()).toISOString(),
      type: "plugin_error",
      plugin: "scoring",
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

  const writeJsonl = (hook, record, context = {}) => {
    try {
      ensureDir();
      fs.appendFileSync(perfFile, JSON.stringify(record) + "\n", "utf-8");
    } catch (err) {
      logError(hook, err, { stage: "write_performance", ...context });
    }
  };

  // Facts are read through the same exported helpers the tests use.
  const factsForTask = (taskId) => {
    if (!taskId) return null;
    const evidence = readEvidenceDir(resolveEvidenceDir(directory, evidenceDir));
    for (const error of evidence.errors) {
      logError("collect_evidence", new Error(error.message), { file: error.file });
    }
    return aggregateEvidence(evidence.records).find((entry) => entry.task_id === taskId) || null;
  };

  // Trace spans of one session (tracer.js output), summarised for the record.
  const traceForSession = (sessionID) => {
    const traces = readTracesDir(targetDir);
    for (const error of traces.errors) {
      logError("collect_traces", new Error(error.message), { file: error.file });
    }
    return summarizeTraces(traces.records).find((entry) => entry.session_id === sessionID) || null;
  };

  return {
    event: async ({ event } = {}) => {
      let eventType = "";
      let sessionID = "";
      try {
        eventType = safeString(safeField(event, "type"));
        const props = safeField(event, "properties") || {};
        sessionID =
          safeString(safeField(props, "sessionID")) ||
          safeString(safeField(safeField(props, "info"), "id"));
        if (!sessionID) return;
        if (eventType === "session.created") {
          if (sessions.size >= MAX_TRACKED_SESSIONS && !sessions.has(sessionID)) {
            sessions.delete(sessions.keys().next().value);
          }
          sessions.set(sessionID, clock());
          return;
        }
        if (eventType !== "session.idle") return;
        const startedAt = sessions.get(sessionID);
        if (startedAt === undefined) return;
        sessions.delete(sessionID);
        const ids = correlationIds();
        const aggregate = factsForTask(ids.task_id);
        writeJsonl(
          "event",
          buildSessionRecord({
            sessionID,
            duration_ms: Math.max(0, clock() - startedAt),
            ts: new Date(clock()).toISOString(),
            task_id: ids.task_id,
            aggregate,
            trace: traceForSession(sessionID),
          }),
          { session_id: sessionID }
        );
      } catch (err) {
        logError("event", err, { event_type: eventType, session_id: sessionID });
      }
    },

    "tool.execute.after": async (input, _output) => {
      try {
        if (safeField(input, "tool") !== "task") return;
        const ids = correlationIds();
        writeJsonl(
          "tool.execute.after",
          {
            ts: new Date(clock()).toISOString(),
            type: "delegation",
            tool: "task", // legacy key
            session_id: safeString(safeField(input, "sessionID")),
            call_id: safeString(safeField(input, "callID")),
            task_id: ids.task_id,
            attempt_id: ids.attempt_id,
            status: "ok",
          },
          { session_id: safeString(safeField(input, "sessionID")) }
        );
      } catch (err) {
        logError("tool.execute.after", err, {
          session_id: safeString(safeField(input, "sessionID")),
        });
      }
    },
  };
};
