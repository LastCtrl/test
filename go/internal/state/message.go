package state

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Message is a bus envelope written by inbox-engine.ps1 into the inbox,
// outbox, archive or dead-letter directory.
type Message struct {
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
	CreatedAt  string          `json:"created_at"`
	Created    string          `json:"created"`
	Agent      string          `json:"-"` // inbox subdirectory, when present
	Path       string          `json:"-"`
}

// PayloadText renders the payload for display. The bus stores it as a plain
// string in some messages and as an object in others; both are supported.
func (m Message) PayloadText() string {
	if len(m.Payload) == 0 {
		return ""
	}

	var asString string
	if err := json.Unmarshal(m.Payload, &asString); err == nil {
		return asString
	}

	var compacted bytes.Buffer
	if err := json.Compact(&compacted, m.Payload); err != nil {
		return string(m.Payload)
	}
	return compacted.String()
}

// LastTimestamp returns the most advanced timestamp of the message.
func (m Message) LastTimestamp() (string, bool) {
	for _, candidate := range []string{m.FinishedAt, m.StartedAt, m.CreatedAt, m.Created} {
		if _, ok := ParseTime(candidate); ok {
			return candidate, true
		}
	}
	return "", false
}

// LoadMessages reads every JSON message inside dir. The inbox stores messages
// one level deeper (.memory/inbox/<agent>/<name>.json), so agent
// subdirectories are scanned as well; the subdirectory name becomes Message
// Agent. Missing directories yield an empty list.
func LoadMessages(dir string) ([]Message, []string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, []string{fmt.Sprintf("messages: cannot list %s: %v", dir, err)}
	}

	messages := make([]Message, 0, len(entries))
	var warnings []string

	appendFile := func(path, agent string) {
		raw, err := os.ReadFile(path)
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("messages: cannot read %s: %v", path, err))
			return
		}
		var message Message
		if err := json.Unmarshal(trimBOM(raw), &message); err != nil {
			warnings = append(warnings, fmt.Sprintf("messages: broken json %s: %v", path, err))
			return
		}
		message.Path = path
		message.Agent = agent
		if strings.TrimSpace(message.ID) == "" {
			message.ID = strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
		}
		messages = append(messages, message)
	}

	for _, entry := range entries {
		switch {
		case entry.IsDir():
			if entry.Name() == ".gitkeep" {
				continue
			}
			nested, err := os.ReadDir(filepath.Join(dir, entry.Name()))
			if err != nil {
				warnings = append(warnings, fmt.Sprintf("messages: cannot list %s: %v", filepath.Join(dir, entry.Name()), err))
				continue
			}
			for _, nestedEntry := range nested {
				if nestedEntry.IsDir() || !strings.HasSuffix(strings.ToLower(nestedEntry.Name()), ".json") {
					continue
				}
				appendFile(filepath.Join(dir, entry.Name(), nestedEntry.Name()), entry.Name())
			}
		case strings.HasSuffix(strings.ToLower(entry.Name()), ".json"):
			appendFile(filepath.Join(dir, entry.Name()), "")
		}
	}

	sort.Slice(messages, func(i, j int) bool { return messages[i].Path < messages[j].Path })
	return messages, warnings
}
