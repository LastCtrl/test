package bus

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"sort"
	"strings"
	"time"
)

// queue.go is the Go twin of the project-queue.ps1 write path for the tasks the
// driver actually executes: pick the next queued/assigned task, mark it
// in_progress, then done or dead.
//
// The document is edited as a generic JSON object (not a struct) on purpose:
// queue tasks carry fields this driver does not know about (dead_reason,
// worktree, retries, operator notes) and a round trip through a struct would
// silently delete them. Numbers are kept as json.Number for the same reason.

// PriorityOrder mirrors $PriorityOrder in project-queue.ps1 (lower runs first).
var PriorityOrder = map[string]int{
	"critical": 0,
	"high":     1,
	"normal":   2,
	"low":      3,
}

// PendingStatuses are the statuses Get-NextTask considers work.
var PendingStatuses = map[string]bool{"queued": true, "assigned": true}

// ErrQueueSave reports a queue document that could not be persisted or failed
// its read-back validation.
var ErrQueueSave = errors.New("cannot save queue")

// Queue is one projects/<project>/queue.json document.
type Queue struct {
	Project string
	Path    string
	doc     map[string]any
	tasks   []map[string]any
}

// LoadQueue reads one queue document. A missing file yields nil, nil; a broken
// file is reported as an error so the caller can warn instead of guessing.
func LoadQueue(root, project string) (*Queue, error) {
	path := ProjectQueuePath(root, project)
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	decoder := json.NewDecoder(bytes.NewReader(trimBOM(raw)))
	decoder.UseNumber()
	var doc map[string]any
	if err := decoder.Decode(&doc); err != nil {
		return nil, err
	}

	queue := &Queue{Project: project, Path: path, doc: doc}
	if name, ok := doc["project"].(string); ok && strings.TrimSpace(name) != "" {
		queue.Project = strings.TrimSpace(name)
	}
	if list, ok := doc["tasks"].([]any); ok {
		for _, item := range list {
			if task, isMap := item.(map[string]any); isMap {
				queue.tasks = append(queue.tasks, task)
			}
		}
	}
	return queue, nil
}

// NextPending returns the highest-priority queued/assigned task, FIFO within the
// same priority, exactly like Get-NextTask.
func (q *Queue) NextPending() (map[string]any, bool) {
	tasks := q.PendingSorted()
	if len(tasks) == 0 {
		return nil, false
	}
	return tasks[0], true
}

// PendingSorted returns every queued/assigned task, ordered the way Get-NextTask
// orders them (priority first, then FIFO by created_at).
func (q *Queue) PendingSorted() []map[string]any {
	pending := make([]map[string]any, 0, len(q.tasks))
	for _, task := range q.tasks {
		if PendingStatuses[strings.ToLower(TaskString(task, "status"))] {
			pending = append(pending, task)
		}
	}
	sort.SliceStable(pending, func(i, j int) bool {
		left := priorityRank(TaskString(pending[i], "priority"))
		right := priorityRank(TaskString(pending[j], "priority"))
		if left != right {
			return left < right
		}
		return TaskString(pending[i], "created_at") < TaskString(pending[j], "created_at")
	})
	return pending
}

// Save persists the document: backup, atomic replace, read-back validation with
// restore from the backup on failure. It mirrors Save-Queue in project-queue.ps1.
func (q *Queue) Save() error {
	encoded, err := json.Marshal(q.doc)
	if err != nil {
		return err
	}

	backupPath := q.Path + ".bak"
	if raw, readErr := os.ReadFile(q.Path); readErr == nil {
		// A failed backup is not fatal (the same trade-off Save-Queue takes).
		_ = os.WriteFile(backupPath, raw, 0o644)
	}
	if err := WriteFileAtomic(q.Path, encoded); err != nil {
		return err
	}

	if verified, readErr := os.ReadFile(q.Path); readErr == nil {
		var check any
		if json.Unmarshal(verified, &check) == nil {
			return nil
		}
	}
	if backup, backupErr := os.ReadFile(backupPath); backupErr == nil {
		_ = os.WriteFile(q.Path, backup, 0o644)
	}
	return ErrQueueSave
}

// TaskString reads a string field of a raw task object.
func TaskString(task map[string]any, key string) string {
	value, ok := task[key]
	if !ok {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return typed
	case json.Number:
		return typed.String()
	case nil:
		return ""
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return ""
		}
		return string(encoded)
	}
}

// SetTaskField sets a string field on a raw task object.
func SetTaskField(task map[string]any, key, value string) {
	task[key] = value
}

// DiscoverQueueProjects lists the project directories that hold a queue.json.
func DiscoverQueueProjects(root string) ([]string, error) {
	projectsDir := ProjectsDir(root)
	entries, err := os.ReadDir(projectsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	projects := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if _, statErr := os.Stat(ProjectQueuePath(root, entry.Name())); statErr == nil {
			projects = append(projects, entry.Name())
		}
	}
	sort.Strings(projects)
	return projects, nil
}

// NowStampFormatted is the queue timestamp shape (Get-Now in project-queue.ps1).
func NowStampFormatted(at time.Time) string {
	return at.Format(ClaimTimeLayout)
}

func priorityRank(priority string) int {
	if rank, ok := PriorityOrder[strings.ToLower(strings.TrimSpace(priority))]; ok {
		return rank
	}
	return 99
}
