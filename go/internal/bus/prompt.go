package bus

import "path/filepath"

// prompt.go holds the worker prompt contract. inbox-engine.ps1 and the Go driver
// must send the same text: the agent is told to read the bus protocol file, to
// end its answer with the status marker and where the task payload is. Keeping
// it in one exported function makes the parity observable instead of accidental.

// BuildPrompt renders the task prompt for root, mirroring the prompt string of
// Process-InboxFile in inbox-engine.ps1.
func BuildPrompt(root, taskText string) string {
	contextBuffer := filepath.Join(root, "CONTEXT-BUFFER.md")
	return "You received a task from agent-hq bus. Read the last 30 lines of " + contextBuffer +
		" (iron rules protocol), execute the task, result write to CONTEXT-BUFFER.md, answer briefly. " +
		"CRITICAL: end your final answer with a line containing exactly 'STATUS: resolved' " +
		"(or 'STATUS: done' if completed) in stdout, otherwise the run is treated as failed. " +
		"TASK: " + taskText
}
