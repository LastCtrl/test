#!/usr/bin/env node
// tests/test-plugins.mjs - self-test for the opencode tracer/scoring plugins (P1-4).
//
// Run:  node tests\test-plugins.mjs      -> exit 0 = all PASS, exit 1 = any FAIL
//
// What is verified (all inside an isolated temp root, nothing touches the real
// %LOCALAPPDATA% traces directory):
//   1. tracer writes correlation fields (session_id/message_id/call_id/agent/
//      task_id/attempt_id/duration_ms/status) and keeps the legacy keys;
//   2. every failure is logged into errors.jsonl instead of being swallowed;
//      a hook that throws does not break the host and is not silent;
//   3. no empty `catch (...) {}` block is left in either plugin (static scan);
//   4. scoring aggregates machine evidence (.memory/evidence/*.json) and the
//      self-report claims of CONTEXT-BUFFER.md deterministically, and the score
//      is derived from facts (exit_code / attempts).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.dirname(HERE);
const PLUGIN_DIR = path.join(REPO_ROOT, ".opencode", "plugins");

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "agent-hq-plugins-"));
// Isolation: if a plugin ever falls back to the env override, it still writes
// into the temp root instead of the real traces directory.
process.env.AGENT_HQ_TRACES_DIR = path.join(tmpRoot, "traces-from-env");

const warnings = [];
console.warn = (...args) => warnings.push(args.map((a) => String(a)).join(" "));
// The plugin .js files sit in a directory without "type": "module" (opencode
// loads them as ESM itself); Node auto-detects ESM and emits a harmless
// MODULE_TYPELESS_PACKAGE_JSON warning. Suppress only that one.
process.removeAllListeners("warning");
process.on("warning", (warning) => {
  if (warning && warning.code === "MODULE_TYPELESS_PACKAGE_JSON") return;
  warnings.push(`[node-warning] ${warning?.message ?? String(warning)}`);
});

const results = [];
const check = (id, passed, note) => {
  const ok = Boolean(passed);
  results.push({ id, ok });
  console.log(`[${ok ? "PASS" : "FAIL"}] ${id} - ${note}`);
};

const readJsonl = (file) => {
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, "utf-8")
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
};

const writeFile = (file, content) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, "utf-8");
};

const importPlugin = (name) => import(pathToFileURL(path.join(PLUGIN_DIR, name)).href);

// Replace strings/template literals and comments with empty placeholders so the
// structural scan below only sees real code.
const stripLiterals = (source) => {
  let out = "";
  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    const next = source[i + 1];
    if (ch === "/" && next === "/") {
      while (i < source.length && source[i] !== "\n") i += 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      i += 2;
      while (i < source.length && !(source[i] === "*" && source[i + 1] === "/")) i += 1;
      i += 2;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") {
      const quote = ch;
      i += 1;
      while (i < source.length && source[i] !== quote) {
        if (source[i] === "\\") i += 1;
        i += 1;
      }
      i += 1;
      out += '""';
      continue;
    }
    out += ch;
    i += 1;
  }
  return out;
};

// Bodies of every catch block, braces balanced.
const catchBodies = (source) => {
  const code = stripLiterals(source);
  const bodies = [];
  const opener = /catch\s*(?:\([^)]*\))?\s*\{/g;
  let match = opener.exec(code);
  while (match) {
    let depth = 1;
    let i = opener.lastIndex;
    while (i < code.length && depth > 0) {
      if (code[i] === "{") depth += 1;
      else if (code[i] === "}") depth -= 1;
      i += 1;
    }
    bodies.push(code.slice(opener.lastIndex, i - 1));
    match = opener.exec(code);
  }
  return bodies;
};

const main = async () => {
  const { TracerPlugin, deriveToolStatus } = await importPlugin("tracer.js");
  const scoring = await importPlugin("scoring.js");

  // -------------------------------------------------------------------------
  // tracer v2
  // -------------------------------------------------------------------------
  const tracesDir = path.join(tmpRoot, "traces");
  const tracer = TracerPlugin({ directory: tmpRoot, tracesDir });

  await tracer["chat.message"]({ sessionID: "ses_1", agent: "dev-1", messageID: "msg_1" }, {});
  await tracer["tool.execute.before"](
    { tool: "bash", sessionID: "ses_1", callID: "call_1", args: { command: "echo hi" } },
    { args: { command: "echo hi" } }
  );
  await tracer["tool.execute.after"](
    { tool: "bash", sessionID: "ses_1", callID: "call_1", args: { command: "echo hi" } },
    { title: "bash", output: "hi", metadata: { exit: 0 } }
  );

  const spans = readJsonl(path.join(tracesDir, "traces.jsonl"));
  const toolSpan = spans.find((span) => span.type === "tool");
  const spanOk =
    toolSpan &&
    toolSpan.tool === "bash" &&
    toolSpan.session_id === "ses_1" &&
    toolSpan.call_id === "call_1" &&
    toolSpan.message_id === "msg_1" &&
    toolSpan.agent === "dev-1" &&
    typeof toolSpan.duration_ms === "number" &&
    toolSpan.duration_ms >= 0 &&
    typeof toolSpan.ms === "number" && // legacy key kept
    toolSpan.status === "ok" &&
    toolSpan.error === null &&
    typeof toolSpan.ts === "string" &&
    toolSpan.ts.includes("T");
  check("tracer/tool-span-correlation", spanOk, `span=${JSON.stringify(toolSpan)}`);

  await tracer["tool.execute.after"](
    { tool: "bash", sessionID: "ses_1", callID: "call_missing" },
    { title: "bash", output: "boom", metadata: { exit: 7 } }
  );
  const failSpan = readJsonl(path.join(tracesDir, "traces.jsonl")).filter(
    (span) => span.type === "tool"
  )[1];
  const derived = deriveToolStatus({ metadata: { exit: 7 } });
  check(
    "tracer/tool-status-from-exit-code",
    failSpan && failSpan.status === "exit:7" && derived.status === "exit:7" && derived.error === null,
    `span_status=${failSpan && failSpan.status}; derived=${JSON.stringify(derived)}`
  );

  await tracer.event({
    event: { type: "session.created", properties: { info: { id: "ses_1" } } },
  });
  await tracer.event({
    event: { type: "session.error", properties: { sessionID: "ses_1", error: { name: "ApiError", message: "boom" } } },
  });
  await tracer.event({ event: { type: "session.idle", properties: { sessionID: "ses_1" } } });
  const lifecycle = readJsonl(path.join(tracesDir, "traces.jsonl"));
  const started = lifecycle.find((rec) => rec.type === "session_start");
  const ended = lifecycle.find((rec) => rec.type === "session_end");
  const sessionError = lifecycle.find((rec) => rec.type === "error");
  check(
    "tracer/session-lifecycle",
    started && started.session_id === "ses_1" && started.id === "ses_1" && ended && ended.session_id === "ses_1" && typeof ended.duration_ms === "number",
    `start=${started && started.session_id}; end=${ended && ended.session_id}; end_duration=${ended && ended.duration_ms}`
  );
  check(
    "tracer/session-error-event",
    sessionError && sessionError.session_id === "ses_1" && sessionError.message === "boom",
    `error=${sessionError && sessionError.message}`
  );

  // hostile input must never break the host process
  const hostile = new Proxy(
    {},
    {
      get() {
        throw new Error("hostile-get");
      },
      has() {
        throw new Error("hostile-get");
      },
      ownKeys() {
        throw new Error("hostile-keys");
      },
    }
  );
  let hostileThrew = false;
  try {
    await tracer.event({ event: hostile });
    await tracer["tool.execute.after"](hostile, hostile);
  } catch (_err) {
    hostileThrew = true;
  }
  check("tracer/hostile-input-no-throw", !hostileThrew, "hook returned normally");

  // a hook body that throws must be logged, not swallowed
  const clockDir = path.join(tmpRoot, "traces-bad-clock");
  let clockCalls = 0;
  const flakyClock = () => {
    clockCalls += 1;
    if (clockCalls > 1) throw new Error("clock-out-of-order");
    return 1000;
  };
  const tracerBadClock = TracerPlugin({ directory: tmpRoot, tracesDir: clockDir, now: flakyClock });
  await tracerBadClock["tool.execute.before"]({ tool: "bash", sessionID: "s1", callID: "c1" }, {});
  await tracerBadClock["tool.execute.after"](
    { tool: "bash", sessionID: "s1", callID: "c1" },
    { metadata: { exit: 0 } }
  );
  const hookErrors = readJsonl(path.join(clockDir, "errors.jsonl"));
  check(
    "tracer/hook-error-is-logged",
    hookErrors.length === 1 &&
      hookErrors[0].plugin === "tracer" &&
      hookErrors[0].hook === "tool.execute.after" &&
      hookErrors[0].type === "plugin_error" &&
      /clock-out-of-order/.test(hookErrors[0].message),
    `errors.jsonl=${JSON.stringify(hookErrors)}`
  );

  // traces.jsonl as a broken location: the write fails, errors.jsonl records it
  const brokenDir = path.join(tmpRoot, "traces-broken");
  fs.mkdirSync(path.join(brokenDir, "traces.jsonl"), { recursive: true });
  const tracerBroken = TracerPlugin({ directory: tmpRoot, tracesDir: brokenDir });
  await tracerBroken["tool.execute.after"]({ tool: "bash", sessionID: "s1", callID: "c1" }, { metadata: { exit: 0 } });
  const writeErrors = readJsonl(path.join(brokenDir, "errors.jsonl"));
  check(
    "tracer/write-failure-is-logged",
    writeErrors.length === 1 && writeErrors[0].stage === "write_traces" && writeErrors[0].hook === "tool.execute.after",
    `errors.jsonl=${JSON.stringify(writeErrors)}`
  );

  // last resort: the traces location cannot even be created -> console.warn
  const notADir = path.join(tmpRoot, "not-a-dir");
  fs.writeFileSync(notADir, "blocking file", "utf-8");
  const tracerNoSink = TracerPlugin({ directory: tmpRoot, tracesDir: notADir });
  await tracerNoSink["tool.execute.after"]({ tool: "bash", sessionID: "s1", callID: "c1" }, { metadata: { exit: 0 } });
  check(
    "tracer/unwritable-sink-warns",
    warnings.some((line) => line.startsWith("[tracer]") && line.includes("errors.jsonl write failed")),
    `warnings=${JSON.stringify(warnings.filter((w) => w.startsWith("[tracer]")))}`
  );

  // -------------------------------------------------------------------------
  // static guard: no silent catch may remain in either plugin
  // -------------------------------------------------------------------------
  const sources = {
    tracer: fs.readFileSync(path.join(PLUGIN_DIR, "tracer.js"), "utf-8"),
    scoring: fs.readFileSync(path.join(PLUGIN_DIR, "scoring.js"), "utf-8"),
  };
  const silentCatches = {};
  const catchReport = {};
  const catchFallback = {};
  const scanned = {};
  const expected = {};
  for (const [name, source] of Object.entries(sources)) {
    const bodies = catchBodies(source);
    scanned[name] = bodies.length;
    // Self-validation of the scanner: it must find every `catch` keyword.
    expected[name] = (stripLiterals(source).match(/\bcatch\s*[( {]/g) || []).length;
    silentCatches[name] = bodies.filter((body) => body.trim() === "").length;
    // Every catch body must either report somewhere (errors.jsonl, console.warn,
    // a collected error list, a documented last-resort assignment) or be one of
    // the two documented defensive accessors that return a neutral fallback.
    catchReport[name] = bodies.filter((body) =>
      /logError\s*\(|warn\s*\(|console\.warn\s*\(|errors\.push\s*\(|lastConsoleError\s*=/.test(body)
    ).length;
    catchFallback[name] = bodies.filter((body) => /return\s+(?:""|undefined|null)\s*;/.test(body)).length;
  }
  check(
    "plugins/no-empty-catch",
    scanned.tracer === expected.tracer &&
      scanned.scoring === expected.scoring &&
      scanned.tracer > 0 &&
      silentCatches.tracer === 0 &&
      silentCatches.scoring === 0,
    `catch blocks: tracer=${scanned.tracer}, scoring=${scanned.scoring}; empty: tracer=${silentCatches.tracer}, scoring=${silentCatches.scoring}`
  );
  check(
    "plugins/every-catch-reports",
    catchReport.tracer + catchFallback.tracer === scanned.tracer &&
      catchReport.scoring + catchFallback.scoring === scanned.scoring &&
      catchFallback.tracer === 2 &&
      catchFallback.scoring === 2 &&
      catchReport.tracer >= 7 &&
      catchReport.scoring >= 7,
    `reporting catches: tracer=${catchReport.tracer}+${catchFallback.tracer} fallback, scoring=${catchReport.scoring}+${catchFallback.scoring} fallback of ${scanned.tracer}/${scanned.scoring}`
  );
  check(
    "plugins/error-sink-present",
    sources.tracer.includes("errors.jsonl") &&
      sources.scoring.includes("errors.jsonl") &&
      sources.tracer.includes("console.warn") &&
      sources.scoring.includes("console.warn"),
    "both plugins have errors.jsonl + console.warn fallback"
  );

  // -------------------------------------------------------------------------
  // scoring v2: machine evidence (facts)
  // -------------------------------------------------------------------------
  const evidenceDir = path.join(tmpRoot, ".memory", "evidence");
  writeFile(
    path.join(evidenceDir, "task-abc.json"),
    JSON.stringify({
      task_id: "task-abc",
      attempts: [
        { task_id: "task-abc", attempt_id: "attempt-1", agent: "dev-1", exit_code: 0, status: "ok", duration_ms: 1200 },
        { task_id: "task-abc", attempt_id: "attempt-2", agent: "dev-1", exit_code: 1, status: "failed", duration_ms: 800 },
      ],
    })
  );
  writeFile(
    path.join(evidenceDir, "task-ok.json"),
    JSON.stringify({
      task_id: "task-ok",
      attempts: [{ task_id: "task-ok", attempt_id: "attempt-1", agent: "qa-engineer", exit_code: 0, status: "ok", duration_ms: 500 }],
    })
  );
  writeFile(path.join(evidenceDir, "task-ghost.json"), JSON.stringify({ task_id: "task-ghost", attempts: [] }));
  writeFile(path.join(evidenceDir, "broken.json"), "{ this is not json");

  const evidence = scoring.readEvidenceDir(evidenceDir);
  check(
    "scoring/read-evidence",
    evidence.records.length === 3 &&
      evidence.errors.length === 1 &&
      evidence.errors[0].file === "broken.json" &&
      evidence.records.map((r) => r.task_id).join(",") === "task-abc,task-ghost,task-ok",
    `records=${evidence.records.length}; errors=${JSON.stringify(evidence.errors)}`
  );

  const aggregates = scoring.aggregateEvidence(evidence.records);
  const abc = aggregates.find((a) => a.task_id === "task-abc");
  const ok = aggregates.find((a) => a.task_id === "task-ok");
  const ghost = aggregates.find((a) => a.task_id === "task-ghost");
  check(
    "scoring/aggregate-facts",
    abc &&
      abc.attempts === 2 &&
      abc.failed === 1 &&
      abc.succeeded === 1 &&
      abc.exit_codes.join(",") === "0,1" &&
      abc.statuses.join(",") === "ok,failed" &&
      abc.duration_ms_total === 2000 &&
      abc.agents.join(",") === "dev-1" &&
      ghost.attempts === 0 &&
      ghost.evidence_file.endsWith("task-ghost.json"),
    `task-abc=${JSON.stringify(abc)}`
  );

  const scoreAbc = scoring.computeTaskScore(abc);
  const scoreOk = scoring.computeTaskScore(ok);
  const scoreGhost = scoring.computeTaskScore(ghost);
  const deterministic = JSON.stringify(scoring.computeTaskScore(abc)) === JSON.stringify(scoring.computeTaskScore(abc));
  check(
    "scoring/fact-score-deterministic",
    scoreAbc.score === 65 &&
      scoreAbc.verdict === "warn" &&
      scoreOk.score === 100 &&
      scoreOk.verdict === "pass" &&
      scoreGhost.verdict === "no_evidence" &&
      deterministic,
    `abc=${scoreAbc.score}/${scoreAbc.verdict}; ok=${scoreOk.score}/${scoreOk.verdict}; ghost=${scoreGhost.verdict}`
  );

  // -------------------------------------------------------------------------
  // scoring v2: traces correlation
  // -------------------------------------------------------------------------
  const traceFixtureDir = path.join(tmpRoot, "traces-fixture");
  const traceLine = (extra) =>
    JSON.stringify({ ts: "2026-01-01T00:00:00.000Z", type: "tool", tool: "bash", duration_ms: 10, status: "ok", agent: "dev-1", ...extra });
  writeFile(
    path.join(traceFixtureDir, "traces.jsonl"),
    [
      traceLine({ session_id: "ses_a", task_id: "task-abc" }),
      traceLine({ session_id: "ses_a", task_id: "task-abc", tool: "edit", status: "exit:5", duration_ms: 20 }),
      traceLine({ session_id: "ses_b", task_id: "", tool: "read", agent: "qa-engineer", duration_ms: 5 }),
      JSON.stringify({ ts: "2026-01-01T00:00:00.000Z", type: "session_start", id: "ses_a", session_id: "ses_a" }),
    ].join("\n") + "\n"
  );

  const traces = scoring.readTracesDir(traceFixtureDir);
  const summaries = scoring.summarizeTraces(traces.records);
  const joined = scoring.correlateTracesWithEvidence(summaries, aggregates);
  const joinedAbc = joined.find((entry) => entry.task_id === "task-abc");
  const joinedOk = joined.find((entry) => entry.task_id === "task-ok");
  check(
    "scoring/traces-correlated-with-evidence",
    traces.records.length === 4 &&
      traces.errors.length === 0 &&
      traces.truncated === false &&
      summaries.length === 2 &&
      summaries[0].session_id === "ses_a" &&
      summaries[0].tool_spans === 2 &&
      summaries[0].tool_failures === 1 &&
      summaries[0].duration_ms_total === 30 &&
      joinedAbc.trace_tool_spans === 2 &&
      joinedAbc.trace_tool_failures === 1 &&
      joinedOk.trace_tool_spans === 0 &&
      joinedOk.traces === null,
    `summaries=${JSON.stringify(summaries)}`
  );

  // The traces file grows unbounded -> only the tail is parsed, the partial
  // first line of that read is dropped and nothing is reported as broken.
  const tailDir = path.join(tmpRoot, "traces-tail");
  const longLines = [];
  for (let index = 0; index < 6; index += 1) {
    longLines.push(JSON.stringify({ type: "tool", session_id: "ses_t", status: "ok", duration_ms: index, pad: "x".repeat(80) }));
  }
  writeFile(path.join(tailDir, "traces.jsonl"), longLines.join("\n") + "\n");
  const tail = scoring.readTracesDir(tailDir, { maxBytes: 300 });
  check(
    "scoring/tail-read-truncation",
    tail.truncated === true &&
      tail.records.length >= 1 &&
      tail.records.length < longLines.length &&
      tail.records.every((record) => record.session_id === "ses_t") &&
      tail.errors.length === 0,
    `truncated=${tail.truncated}; records=${tail.records.length}/${longLines.length}; errors=${tail.errors.length}`
  );

  // -------------------------------------------------------------------------
  // scoring v2: self-report correlation
  // -------------------------------------------------------------------------
  writeFile(
    path.join(tmpRoot, "CONTEXT-BUFFER.md"),
    [
      "# CONTEXT BUFFER",
      "",
      "[TIME] dev-1 -> team-lead:",
      "TYPE: update | PRIORITY: medium",
      "CONTENT: P1-4 done, evidence: .memory/evidence/task-abc.json",
      "STATUS: resolved",
      "",
      "====================",
      "",
      "[TIME] qa-engineer -> team-lead:",
      "TYPE: update | PRIORITY: medium",
      "CONTENT: verified (task-ok)",
      "STATUS: resolved",
      "",
      "[TIME] dev-2 -> team-lead:",
      "TYPE: blocker | PRIORITY: critical",
      "CONTENT: claimed done without evidence (task-ghost)",
      "STATUS: resolved",
      "",
    ].join("\n")
  );

  const reports = scoring.parseSelfReports(fs.readFileSync(path.join(tmpRoot, "CONTEXT-BUFFER.md"), "utf-8"));
  check(
    "scoring/self-report-parse",
    reports.length === 3 &&
      reports[0].agent === "dev-1" &&
      reports[0].status === "resolved" &&
      reports[0].task_ids.includes("task-abc") &&
      reports[1].agent === "qa-engineer" &&
      reports[2].task_ids.includes("task-ghost"),
    `reports=${JSON.stringify(reports.map((r) => [r.agent, r.status, r.task_ids]))}`
  );

  const correlated = scoring.correlateSelfReports(aggregates, reports);
  const corrAbc = correlated.find((a) => a.task_id === "task-abc");
  const corrOk = correlated.find((a) => a.task_id === "task-ok");
  const corrGhost = correlated.find((a) => a.task_id === "task-ghost");
  check(
    "scoring/correlate-false-done",
    corrAbc.claimed_status === "resolved" &&
      corrAbc.false_done === true &&
      corrOk.claimed_status === "resolved" &&
      corrOk.false_done === false,
    `task-abc false_done=${corrAbc.false_done}; task-ok false_done=${corrOk.false_done}`
  );
  check(
    "scoring/correlate-unverified",
    corrGhost.unverified === true && corrGhost.false_done === false,
    `task-ghost unverified=${corrGhost.unverified}`
  );

  const facts = scoring.collectScoringFacts({ directory: tmpRoot, tracesDir: traceFixtureDir });
  check(
    "scoring/collect-facts",
    facts.aggregates.length === 3 &&
      facts.reports.length === 3 &&
      facts.errors.length === 1 &&
      facts.traces.count === 4 &&
      facts.aggregates.find((a) => a.task_id === "task-abc").false_done === true &&
      facts.aggregates.find((a) => a.task_id === "task-abc").trace_tool_spans === 2,
    `aggregates=${facts.aggregates.length}; reports=${facts.reports.length}; errors=${facts.errors.length}; traces=${facts.traces.count}`
  );

  // -------------------------------------------------------------------------
  // scoring v2: plugin wiring (deterministic clock)
  // -------------------------------------------------------------------------
  const perfDir = path.join(tmpRoot, "perf");
  writeFile(
    path.join(perfDir, "traces.jsonl"),
    [
      JSON.stringify({ type: "tool", tool: "bash", session_id: "ses_perf", status: "ok", duration_ms: 7, agent: "dev-1", task_id: "task-abc" }),
      JSON.stringify({ type: "tool", tool: "edit", session_id: "ses_perf", status: "exit:1", duration_ms: 3, agent: "dev-1", task_id: "task-abc" }),
    ].join("\n") + "\n"
  );
  process.env.AGENT_HQ_TASK_ID = "task-abc";
  process.env.AGENT_HQ_ATTEMPT_ID = "attempt-2";
  let fakeNow = 1000;
  const scoringPlugin = scoring.ScoringPlugin({ directory: tmpRoot, tracesDir: perfDir, now: () => fakeNow });
  await scoringPlugin.event({ event: { type: "session.created", properties: { info: { id: "ses_perf" } } } });
  fakeNow = 46000;
  await scoringPlugin.event({ event: { type: "session.idle", properties: { sessionID: "ses_perf" } } });
  fakeNow = 50000;
  await scoringPlugin["tool.execute.after"]({ tool: "task", sessionID: "ses_perf", callID: "call_9" }, {});

  const perfRecords = readJsonl(path.join(perfDir, "performance.jsonl"));
  const sessionRecord = perfRecords.find((rec) => rec.type === "session");
  const delegation = perfRecords.find((rec) => rec.type === "delegation");
  check(
    "scoring/performance-record",
    sessionRecord &&
      sessionRecord.session_id === "ses_perf" &&
      sessionRecord.duration_ms === 45000 &&
      sessionRecord.score === 99 &&
      sessionRecord.task_id === "task-abc" &&
      sessionRecord.attempts === 2 &&
      sessionRecord.failed === 1 &&
      sessionRecord.exit_codes.join(",") === "0,1" &&
      sessionRecord.fact_score === 65 &&
      sessionRecord.verdict === "warn" &&
      sessionRecord.trace_tool_spans === 2 &&
      sessionRecord.trace_tool_failures === 1 &&
      sessionRecord.ts === "1970-01-01T00:00:46.000Z",
    `session=${JSON.stringify(sessionRecord)}`
  );
  check(
    "scoring/delegation-correlated",
    delegation && delegation.tool === "task" && delegation.call_id === "call_9" && delegation.session_id === "ses_perf" && delegation.task_id === "task-abc",
    `delegation=${JSON.stringify(delegation)}`
  );

  const perfBrokenDir = path.join(tmpRoot, "perf-broken");
  fs.mkdirSync(path.join(perfBrokenDir, "performance.jsonl"), { recursive: true });
  const scoringBroken = scoring.ScoringPlugin({ directory: tmpRoot, tracesDir: perfBrokenDir, now: () => 0 });
  await scoringBroken["tool.execute.after"]({ tool: "task", sessionID: "s", callID: "c" }, {});
  const scoringErrors = readJsonl(path.join(perfBrokenDir, "errors.jsonl"));
  check(
    "scoring/write-failure-is-logged",
    scoringErrors.length === 1 && scoringErrors[0].plugin === "scoring" && scoringErrors[0].stage === "write_performance",
    `errors.jsonl=${JSON.stringify(scoringErrors)}`
  );

  let scoringHostileThrew = false;
  try {
    await scoringPlugin.event({ event: hostile });
    await scoringPlugin["tool.execute.after"](hostile, hostile);
  } catch (_err) {
    scoringHostileThrew = true;
  }
  check("scoring/hostile-input-no-throw", !scoringHostileThrew, "hook returned normally");
};

let fatal = null;
try {
  await main();
} catch (err) {
  fatal = err;
  check("test-harness/no-uncaught-exception", false, `unexpected exception: ${err && err.stack}`);
} finally {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
  delete process.env.AGENT_HQ_TASK_ID;
  delete process.env.AGENT_HQ_ATTEMPT_ID;
}

const passed = results.filter((r) => r.ok).length;
const failed = results.length - passed;
console.log("");
console.log(`RESULT: ${passed}/${results.length} passed, ${failed} failed`);
if (fatal) console.log(`FATAL: ${fatal && fatal.message}`);
process.exit(failed === 0 && !fatal ? 0 : 1);
