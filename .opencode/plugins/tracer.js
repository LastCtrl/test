import fs from "node:fs";
import path from "node:path";
import os from "node:os";

export const TracerPlugin = ({ directory }) => {
  const starts = new Map();
  const tracesDir = path.join(
    process.env.LOCALAPPDATA || process.env.APPDATA || os.tmpdir(),
    "opencode",
    "agent-hq-traces"
  );
  const tracesFile = path.join(tracesDir, "traces.jsonl");

  const writeJsonl = (obj) => {
    try {
      fs.mkdirSync(tracesDir, { recursive: true });
      fs.appendFileSync(tracesFile, JSON.stringify(obj) + "\n", "utf-8");
    } catch (_) {}
  };

  return {
    "tool.execute.before": async (input, _output) => {
      try {
        const callID = input?.callID;
        if (callID) {
          if (starts.size >= 1000) {
            const oldest = starts.keys().next().value;
            starts.delete(oldest);
          }
          starts.set(callID, Date.now());
        }
      } catch (_) {}
    },

    "tool.execute.after": async (input, _output) => {
      try {
        const callID = input?.callID;
        const ms = callID && starts.has(callID) ? Date.now() - starts.get(callID) : 0;
        if (callID) starts.delete(callID);
        writeJsonl({
          ts: new Date().toISOString(),
          type: "tool",
          tool: input?.tool,
          ms,
        });
      } catch (_) {}
    },

    event: async ({ event }) => {
      try {
        const id = event?.properties?.sessionID;
        if (!id) return;
        if (event?.type === "session.created") {
          writeJsonl({ ts: new Date().toISOString(), type: "session_start", id });
        } else if (event?.type === "session.error") {
          const props = event?.properties ?? event ?? {};
          const msg =
            props.message ??
            props.error ??
            props.data ??
            props.reason ??
            props.detail ??
            "";
          const raw = JSON.stringify(props, null, 0);
          writeJsonl({
            ts: new Date().toISOString(),
            type: "error",
            id,
            message: String(msg).slice(0, 300),
            props: String(raw).slice(0, 500),
          });
        } else if (event?.type === "session.idle") {
          writeJsonl({ ts: new Date().toISOString(), type: "session_end", id });
        }
      } catch (_) {}
    },
  };
};
