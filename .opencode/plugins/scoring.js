import fs from "node:fs";
import path from "node:path";
import os from "node:os";

export const ScoringPlugin = ({ directory }) => {
  const sessions = new Map();
  const tracesDir = path.join(
    process.env.LOCALAPPDATA || process.env.APPDATA || os.tmpdir(),
    "opencode",
    "agent-hq-traces"
  );
  const perfFile = path.join(tracesDir, "performance.jsonl");

  const writeJsonl = (obj) => {
    try {
      fs.mkdirSync(tracesDir, { recursive: true });
      fs.appendFileSync(perfFile, JSON.stringify(obj) + "\n", "utf-8");
    } catch (_) {}
  };

  return {
    event: async ({ event }) => {
      try {
        const id = event?.properties?.sessionID;
        if (!id) return;
        if (event?.type === "session.created") {
          sessions.set(id, Date.now());
        } else if (event?.type === "session.idle") {
          const start = sessions.get(id);
          if (start !== undefined) {
            const duration_ms = Date.now() - start;
            const score = Math.max(0, 100 - Math.round(duration_ms / 60000));
            writeJsonl({
              ts: new Date().toISOString(),
              session_id: id,
              duration_ms,
              score,
            });
            sessions.delete(id);
          }
        }
      } catch (_) {}
    },

    "tool.execute.after": async (input, _output) => {
      try {
        if (input?.tool === "task") {
          writeJsonl({
            ts: new Date().toISOString(),
            type: "delegation",
            tool: "task",
          });
        }
      } catch (_) {}
    },
  };
};
