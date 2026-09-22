package state

import (
	"sort"
	"time"
)

// Snapshot is one read-only view of the repository state. Every slice is
// sorted; Warnings collects non-fatal problems (missing or malformed files)
// found while loading, so callers can report partial results honestly.
type Snapshot struct {
	Root       string
	Version    string
	LoadedAt   time.Time
	Evidence   []EvidenceDoc
	Claims     []ClaimStatus
	Queues     []Queue
	Inbox      []Message
	Outbox     []Message
	DeadLetter []Message
	Warnings   []string
}

// Load builds a snapshot from the on-disk state below root. It never fails:
// missing directories are empty and malformed files are recorded as warnings.
func Load(root, version string, ttlOverride time.Duration, now time.Time) *Snapshot {
	snapshot := &Snapshot{
		Root:     root,
		Version:  version,
		LoadedAt: now,
	}

	evidence, warnings := LoadEvidence(root)
	snapshot.Evidence = evidence
	snapshot.Warnings = append(snapshot.Warnings, warnings...)

	claims, warnings := LoadClaims(root)
	snapshot.Claims = EvaluateClaims(claims, ttlOverride, now)
	snapshot.Warnings = append(snapshot.Warnings, warnings...)

	queues, warnings := LoadQueues(root)
	snapshot.Queues = queues
	snapshot.Warnings = append(snapshot.Warnings, warnings...)

	inbox, warnings := LoadMessages(InboxDir(root))
	snapshot.Inbox = inbox
	snapshot.Warnings = append(snapshot.Warnings, warnings...)

	outbox, warnings := LoadMessages(OutboxDir(root))
	snapshot.Outbox = outbox
	snapshot.Warnings = append(snapshot.Warnings, warnings...)

	deadLetter, warnings := LoadMessages(DeadLetterDir(root))
	snapshot.DeadLetter = deadLetter
	snapshot.Warnings = append(snapshot.Warnings, warnings...)

	return snapshot
}

// Counts is the numeric summary used by the status command.
type Counts struct {
	Evidence         int `json:"evidence"`
	EvidenceAttempts int `json:"evidence_attempts"`
	Claims           int `json:"claims"`
	StaleClaims      int `json:"stale_claims"`
	Inbox            int `json:"inbox"`
	Outbox           int `json:"outbox"`
	DeadLetter       int `json:"dead_letter"`
	QueueTasks       int `json:"queue_tasks"`
	Projects         int `json:"projects"`
}

// Counts summarizes the snapshot.
func (s *Snapshot) Counts() Counts {
	counts := Counts{
		Evidence:   len(s.Evidence),
		Claims:     len(s.Claims),
		Inbox:      len(s.Inbox),
		Outbox:     len(s.Outbox),
		DeadLetter: len(s.DeadLetter),
		Projects:   len(s.Queues),
	}
	for _, doc := range s.Evidence {
		counts.EvidenceAttempts += len(doc.Attempts)
	}
	for _, claim := range s.Claims {
		if claim.Stale {
			counts.StaleClaims++
		}
	}
	counts.QueueTasks = TaskCount(s.Queues)
	return counts
}

// Tasks flattens every queued project task, sorted by project then identifier.
func (s *Snapshot) Tasks() []Task {
	tasks := make([]Task, 0)
	for _, queue := range s.Queues {
		tasks = append(tasks, queue.Tasks...)
	}
	sort.SliceStable(tasks, func(i, j int) bool {
		if tasks[i].Project != tasks[j].Project {
			return tasks[i].Project < tasks[j].Project
		}
		return tasks[i].ID < tasks[j].ID
	})
	return tasks
}

// EvidenceByTaskID returns the evidence document for the given identifier.
func (s *Snapshot) EvidenceByTaskID(taskID string) (EvidenceDoc, bool) {
	for _, doc := range s.Evidence {
		if doc.TaskID == taskID {
			return doc, true
		}
	}
	return EvidenceDoc{}, false
}

// Activity is one entry of the merged recent-activity feed.
type Activity struct {
	Source   string `json:"source"`
	ID       string `json:"id"`
	Title    string `json:"title,omitempty"`
	Project  string `json:"project,omitempty"`
	Agent    string `json:"agent,omitempty"`
	Status   string `json:"status,omitempty"`
	Priority string `json:"priority,omitempty"`
	Time     string `json:"time,omitempty"`
	sortTime time.Time
}

// RecentActivity merges queue tasks, evidence documents, leases and bus
// messages into one feed ordered newest first. A limit <= 0 returns all
// entries; entries without a parsable timestamp are dropped.
func (s *Snapshot) RecentActivity(limit int) []Activity {
	activities := make([]Activity, 0)

	for _, task := range s.Tasks() {
		timestamp, ok := task.LastTimestamp()
		if !ok {
			continue
		}
		parsed, _ := ParseTime(timestamp)
		activities = append(activities, Activity{
			Source:   "queue",
			ID:       task.ID,
			Title:    task.Title,
			Project:  task.Project,
			Agent:    task.AssignedAgent,
			Status:   task.Status,
			Priority: task.Priority,
			Time:     timestamp,
			sortTime: parsed,
		})
	}

	for _, doc := range s.Evidence {
		finished, ok := doc.LastFinished()
		if !ok {
			continue
		}
		status := ""
		if len(doc.Attempts) > 0 {
			status = doc.Attempts[len(doc.Attempts)-1].Status
		}
		agents := doc.Agents()
		agent := ""
		if len(agents) > 0 {
			agent = agents[0]
		}
		activities = append(activities, Activity{
			Source:   "evidence",
			ID:       doc.TaskID,
			Agent:    agent,
			Status:   status,
			Time:     finished.Format(time.RFC3339),
			sortTime: finished,
		})
	}

	for _, claim := range s.Claims {
		parsed, ok := ParseTime(claim.HeartbeatAt)
		if !ok {
			continue
		}
		status := "leased"
		if claim.Stale {
			status = "lease-stale"
		}
		activities = append(activities, Activity{
			Source:   "claim",
			ID:       claim.TaskID,
			Agent:    claim.Agent,
			Status:   status,
			Time:     claim.HeartbeatAt,
			sortTime: parsed,
		})
	}

	for _, message := range s.Inbox {
		appendMessageActivity(&activities, "inbox", message)
	}
	for _, message := range s.Outbox {
		appendMessageActivity(&activities, "outbox", message)
	}
	for _, message := range s.DeadLetter {
		appendMessageActivity(&activities, "dead-letter", message)
	}

	sort.SliceStable(activities, func(i, j int) bool {
		return activities[i].sortTime.After(activities[j].sortTime)
	})
	if limit > 0 && len(activities) > limit {
		activities = activities[:limit]
	}
	return activities
}

func appendMessageActivity(activities *[]Activity, source string, message Message) {
	timestamp, ok := message.LastTimestamp()
	if !ok {
		return
	}
	parsed, _ := ParseTime(timestamp)
	agent := message.Agent
	if agent == "" {
		agent = message.To
	}
	*activities = append(*activities, Activity{
		Source:   source,
		ID:       message.ID,
		Agent:    agent,
		Status:   message.Status,
		Priority: message.Priority,
		Time:     timestamp,
		sortTime: parsed,
	})
}
