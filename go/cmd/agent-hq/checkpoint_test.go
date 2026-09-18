package main

import (
	"bytes"
	"encoding/json"
	"testing"

	"agent-hq/internal/store"
)

func TestCheckpointCommandRoundTrip(t *testing.T) {
	root := newCmdRoot(t)
	_ = openCmdStore(t, root) // create the database the read-only subcommands need

	var stdout, stderr bytes.Buffer
	code := runCheckpoint(globalOptions{root: root, json: true},
		[]string{"save", "run-cp", "-state", "step 1", "-path", "src/app.go"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("save exit = %d, stderr = %s", code, stderr.String())
	}
	var saved store.RunCheckpoint
	if err := json.Unmarshal(stdout.Bytes(), &saved); err != nil {
		t.Fatalf("decode save: %v (%s)", err, stdout.String())
	}
	if saved.Seq != 1 || saved.State != "step 1" || saved.Path != "src/app.go" || saved.CreatedAt == "" {
		t.Fatalf("saved = %+v, want seq 1 with state, path and timestamp", saved)
	}

	stdout.Reset()
	code = runCheckpoint(globalOptions{root: root, json: true},
		[]string{"save", "run-cp", "-state", "step 2"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("second save exit = %d, stderr = %s", code, stderr.String())
	}
	var second store.RunCheckpoint
	if err := json.Unmarshal(stdout.Bytes(), &second); err != nil {
		t.Fatalf("decode second save: %v", err)
	}
	if second.Seq != 2 {
		t.Errorf("second seq = %d, want 2", second.Seq)
	}

	stdout.Reset()
	code = runCheckpoint(globalOptions{root: root, json: true}, []string{"list", "run-cp"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("list exit = %d, stderr = %s", code, stderr.String())
	}
	var list []store.RunCheckpoint
	if err := json.Unmarshal(stdout.Bytes(), &list); err != nil {
		t.Fatalf("decode list: %v (%s)", err, stdout.String())
	}
	if len(list) != 2 || list[0].Seq != 1 || list[1].Seq != 2 {
		t.Errorf("list = %+v, want two ordered checkpoints", list)
	}

	stdout.Reset()
	code = runCheckpoint(globalOptions{root: root, json: true}, []string{"latest", "run-cp"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("latest exit = %d, stderr = %s", code, stderr.String())
	}
	var latest store.RunCheckpoint
	if err := json.Unmarshal(stdout.Bytes(), &latest); err != nil {
		t.Fatalf("decode latest: %v", err)
	}
	if latest.Seq != 2 || latest.State != "step 2" {
		t.Errorf("latest = %+v, want seq 2 step 2", latest)
	}

	stdout.Reset()
	stderr.Reset()
	code = runCheckpoint(globalOptions{root: root, json: true}, []string{"latest", "missing"}, &stdout, &stderr)
	if code != 1 {
		t.Errorf("latest missing exit = %d, want 1", code)
	}
}

func TestCheckpointCommandUsage(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := runCheckpoint(globalOptions{}, nil, &stdout, &stderr); code != 2 {
		t.Errorf("bare checkpoint exit = %d, want 2", code)
	}
	stderr.Reset()
	if code := runCheckpoint(globalOptions{}, []string{"bogus"}, &stdout, &stderr); code != 2 {
		t.Errorf("unknown checkpoint subcommand exit = %d, want 2", code)
	}
	stderr.Reset()
	if code := runCheckpoint(globalOptions{}, []string{"save"}, &stdout, &stderr); code != 2 {
		t.Errorf("save without a run id exit = %d, want 2", code)
	}
}

func TestExtractCheckpointOptions(t *testing.T) {
	options, rest := extractCheckpointOptions([]string{"run-1", "-state=handoff", "-path", "a/b.go"})
	if options.state != "handoff" || options.path != "a/b.go" || len(rest) != 1 || rest[0] != "run-1" {
		t.Errorf("options = %+v, rest = %v; want state/path and one positional", options, rest)
	}
}
