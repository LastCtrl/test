package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Task is one entry of projects/<project>/queue.json (project-queue.ps1).
type Task struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	Priority      string `json:"priority"`
	Status        string `json:"status"`
	AssignedAgent string `json:"assigned_agent"`
	Project       string `json:"project"`
	Worktree      string `json:"worktree"`
	CreatedAt     string `json:"created_at"`
	StartedAt     string `json:"started_at"`
	CompletedAt   string `json:"completed_at"`
	Retries       *int   `json:"retries"`
	Source        string `json:"-"`
	QueuePath     string `json:"-"`
}

// RetryCount returns the recorded retry counter, or 0.
func (t Task) RetryCount() int {
	if t.Retries == nil {
		return 0
	}
	return *t.Retries
}

// LastTimestamp returns the most advanced lifecycle timestamp of the task.
func (t Task) LastTimestamp() (string, bool) {
	for _, candidate := range []string{t.CompletedAt, t.StartedAt, t.CreatedAt} {
		if _, ok := ParseTime(candidate); ok {
			return candidate, true
		}
	}
	return "", false
}

// Queue is the whole projects/<project>/queue.json document.
type Queue struct {
	Project string `json:"project"`
	Path    string `json:"-"`
	Tasks   []Task `json:"tasks"`
}

// LoadQueues reads projects/*/queue.json for every project directory. A
// missing projects directory yields an empty list; malformed queues become
// warnings so one broken project never hides the others.
func LoadQueues(root string) ([]Queue, []string) {
	projectsDir := ProjectsDir(root)
	entries, err := os.ReadDir(projectsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, []string{fmt.Sprintf("queues: cannot list %s: %v", projectsDir, err)}
	}

	queues := make([]Queue, 0, len(entries))
	var warnings []string

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		queuePath := filepath.Join(projectsDir, entry.Name(), QueueFileName)
		raw, err := os.ReadFile(queuePath)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			warnings = append(warnings, fmt.Sprintf("queues: cannot read %s: %v", queuePath, err))
			continue
		}

		var queue Queue
		if err := json.Unmarshal(trimBOM(raw), &queue); err != nil {
			warnings = append(warnings, fmt.Sprintf("queues: broken json %s: %v", queuePath, err))
			continue
		}
		queue.Path = queuePath
		queue.Project = strings.TrimSpace(queue.Project)
		if queue.Project == "" {
			queue.Project = entry.Name()
		}
		for index := range queue.Tasks {
			queue.Tasks[index].Source = "queue"
			queue.Tasks[index].QueuePath = queuePath
			if strings.TrimSpace(queue.Tasks[index].Project) == "" {
				queue.Tasks[index].Project = queue.Project
			}
		}
		queues = append(queues, queue)
	}

	sort.Slice(queues, func(i, j int) bool { return queues[i].Project < queues[j].Project })
	return queues, warnings
}

// TaskCount returns the total number of queued tasks across every project.
func TaskCount(queues []Queue) int {
	total := 0
	for _, queue := range queues {
		total += len(queue.Tasks)
	}
	return total
}
