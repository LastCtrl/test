package bus

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// message.go owns the inbox -> outbox/dead-letter/archive lifecycle. It is the
// Go twin of Process-InboxFile in inbox-engine.ps1: same routing (the `to` field
// wins over the folder name), same envelope keys, same destinations and the same
// behaviour on a broken inbox file.

// InboxMessage is one pending bus message read from .memory/inbox/<agent>/*.json.
type InboxMessage struct {
	ID       string          `json:"id"`
	From     string          `json:"from"`
	To       string          `json:"to"`
	Type     string          `json:"type"`
	Priority string          `json:"priority"`
	Payload  json.RawMessage `json:"payload"`
	Source   string          `json:"source"`
	Created  string          `json:"created"`
	// Agent is the inbox subdirectory the file lives in; it is the fallback
	// target when the message has no `to` field.
	Agent string `json:"-"`
	// FilePath is the absolute location of the inbox file.
	FilePath string `json:"-"`
}

// PayloadText renders the payload the way the PowerShell engine does: a JSON
// string payload is unwrapped, anything else keeps its compact JSON form.
func (m InboxMessage) PayloadText() string {
	if len(m.Payload) == 0 {
		return ""
	}
	var asString string
	if err := json.Unmarshal(m.Payload, &asString); err == nil {
		return asString
	}
	trimmed := strings.TrimSpace(string(m.Payload))
	if trimmed == "null" {
		return ""
	}
	return trimmed
}

// TargetAgent is the agent that must run the message: its `to` field, otherwise
// the folder it was found in.
func (m InboxMessage) TargetAgent() string {
	if agent := strings.TrimSpace(m.To); agent != "" {
		return agent
	}
	return strings.TrimSpace(m.Agent)
}

// IsInteractive reports whether the message came from the conversational path.
// Those answers ARE the result, so the STATUS marker is optional for them.
func (m InboxMessage) IsInteractive() bool {
	source := strings.ToLower(strings.TrimSpace(m.Source))
	return source == "run" || source == "reply" || strings.EqualFold(strings.TrimSpace(m.From), "telegram")
}

// ScanInbox lists every pending inbox file, ordered by full path, exactly like
// Get-PendingInboxItems in inbox-engine.ps1.
func ScanInbox(root string) ([]InboxMessage, []string) {
	dir := InboxDir(root)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, []string{"inbox: cannot list " + dir + ": " + err.Error()}
	}

	messages := make([]InboxMessage, 0)
	var warnings []string
	for _, entry := range entries {
		if !entry.IsDir() || entry.Name() == ".gitkeep" {
			continue
		}
		agentDir := filepath.Join(dir, entry.Name())
		files, err := os.ReadDir(agentDir)
		if err != nil {
			warnings = append(warnings, "inbox: cannot list "+agentDir+": "+err.Error())
			continue
		}
		for _, file := range files {
			if file.IsDir() || !strings.HasSuffix(strings.ToLower(file.Name()), ".json") {
				continue
			}
			messages = append(messages, InboxMessage{
				FilePath: filepath.Join(agentDir, file.Name()),
				Agent:    entry.Name(),
			})
		}
	}
	sort.Slice(messages, func(i, j int) bool { return messages[i].FilePath < messages[j].FilePath })
	return messages, warnings
}

// ParseInboxFile reads and decodes one inbox file. A malformed file is not an
// error the caller can retry: the engine dead-letters it unchanged.
func ParseInboxFile(message InboxMessage) (InboxMessage, error) {
	raw, err := os.ReadFile(message.FilePath)
	if err != nil {
		return message, err
	}
	decoded := message
	if err := json.Unmarshal(trimBOM(raw), &decoded); err != nil {
		return message, err
	}
	decoded.FilePath = message.FilePath
	decoded.Agent = message.Agent
	if strings.TrimSpace(decoded.ID) == "" {
		decoded.ID = BaseName(message.FilePath)
	}
	return decoded, nil
}

// Envelope is an outbox or dead-letter message. Payload keeps the raw JSON of the
// inbox payload, so a string payload stays a string and an object payload stays
// an object, exactly as the PowerShell engine round-trips it.
type Envelope struct {
	ID         string          `json:"id"`
	From       string          `json:"from"`
	To         string          `json:"to"`
	Type       string          `json:"type"`
	Priority   string          `json:"priority"`
	Payload    json.RawMessage `json:"payload"`
	Status     string          `json:"status"`
	StartedAt  string          `json:"startedAt"`
	FinishedAt string          `json:"finishedAt"`
	Response   string          `json:"response"`
	Evidence   string          `json:"evidence"`
}

// NormalizePayload guarantees the payload field is always present in the
// persisted envelope (the PowerShell engine writes "" for a missing payload).
func NormalizePayload(payload json.RawMessage) json.RawMessage {
	if len(payload) == 0 {
		return json.RawMessage(`""`)
	}
	return payload
}

// WriteOutbox writes the success envelope and archives the inbox file as
// <agent>-<original name>. It mirrors Complete-InboxFile.
func WriteOutbox(root, agent, originalName string, envelope Envelope) (string, error) {
	outboxPath := filepath.Join(OutboxDir(root), envelope.ID+".json")
	encoded, err := json.MarshalIndent(envelope, "", "  ")
	if err != nil {
		return "", err
	}
	if err := WriteFileAtomic(outboxPath, append(encoded, '\n')); err != nil {
		return "", err
	}
	return outboxPath, nil
}

// ArchiveInbox moves a processed inbox file to .memory/archive/<agent>-<name>.
func ArchiveInbox(root, filePath, agent string) (string, error) {
	if err := EnsureDir(ArchiveDir(root)); err != nil {
		return "", err
	}
	target := filepath.Join(ArchiveDir(root), agent+"-"+FileName(filePath))
	if err := renameWithRetry(filePath, target); err != nil {
		return "", err
	}
	return target, nil
}

// WriteDeadLetter writes the failure envelope and removes the inbox file. It
// mirrors Send-DeadLetter.
func WriteDeadLetter(root, filePath string, envelope Envelope) (string, error) {
	deadLetterPath := filepath.Join(DeadLetterDir(root), envelope.ID+".json")
	encoded, err := json.MarshalIndent(envelope, "", "  ")
	if err != nil {
		return "", err
	}
	if err := WriteFileAtomic(deadLetterPath, append(encoded, '\n')); err != nil {
		return "", err
	}
	if strings.TrimSpace(filePath) != "" {
		if err := os.Remove(filePath); err != nil && !os.IsNotExist(err) {
			return deadLetterPath, err
		}
	}
	return deadLetterPath, nil
}

// MoveToDeadLetterUnparsed moves a file the engine could not parse into
// .memory/dead-letter unchanged, exactly like the parse-error branch of
// Process-InboxFile (the raw bytes are preserved, no envelope is written).
func MoveToDeadLetterUnparsed(root, filePath string) (string, error) {
	if err := EnsureDir(DeadLetterDir(root)); err != nil {
		return "", err
	}
	target := filepath.Join(DeadLetterDir(root), BaseName(filePath)+".json")
	if err := renameWithRetry(filePath, target); err != nil {
		return "", err
	}
	return target, nil
}

// trimBOM removes a UTF-8 byte order mark, mirroring the PowerShell readers.
func trimBOM(raw []byte) []byte {
	return []byte(strings.TrimPrefix(string(raw), "\ufeff"))
}
