package net

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeHealthFile(t *testing.T, root, content string) string {
	t.Helper()
	path := ModelHealthPath(root)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write health: %v", err)
	}
	return path
}

func TestReadModelHealthFile(t *testing.T) {
	root := t.TempDir()
	document := `{
	  "opencode/mimo-v2.5-free": {"model": "opencode/mimo-v2.5-free", "status": "OK",
	    "checked_at": "2026-09-16T13:20:22", "fail_count": 0, "open_until": ""},
	  "tokenrouter/glm-5.3-free": {"model": "tokenrouter/glm-5.3-free", "status": "TIMEOUT",
	    "checked_at": "2026-09-16T13:21:50", "fail_count": 2, "open_until": "2026-09-16T13:36:50"}
	}`
	path := writeHealthFile(t, root, document)
	now := time.Date(2026, 9, 16, 13, 30, 0, 0, time.Local)

	records, err := ReadModelHealthFile(path, now)
	if err != nil {
		t.Fatalf("ReadModelHealthFile: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("records = %d, want 2", len(records))
	}
	if records[0].Model != "opencode/mimo-v2.5-free" || records[0].Open || records[0].Class != StatusOK {
		t.Errorf("record[0] = %+v, want a closed OK record", records[0])
	}
	if !records[1].Open || records[1].Class != StatusTimeout || records[1].FailCount != 2 {
		t.Errorf("record[1] = %+v, want an open TIMEOUT record with 2 fails", records[1])
	}

	// Once the cooldown elapsed the breaker is closed again.
	records, err = ReadModelHealthFile(path, time.Date(2026, 9, 16, 14, 0, 0, 0, time.Local))
	if err != nil {
		t.Fatalf("ReadModelHealthFile after cooldown: %v", err)
	}
	if records[1].Open {
		t.Errorf("record[1] still open after cooldown: %+v", records[1])
	}
}

func TestReadModelHealthToleratesBOMAndFallbackKey(t *testing.T) {
	root := t.TempDir()
	path := writeHealthFile(t, root, "\uFEFF{\"some/model\": {\"status\": \"DEAD\", \"open_until\": \"not-a-time\"}}")

	records, err := ReadModelHealthFile(path, time.Now())
	if err != nil {
		t.Fatalf("ReadModelHealthFile: %v", err)
	}
	if len(records) != 1 || records[0].Model != "some/model" {
		t.Fatalf("records = %+v, want the map key as the model id", records)
	}
	if records[0].Open {
		t.Error("an unparsable open_until must mean closed (mirrors Test-ModelOpen)")
	}
}

func TestReadModelHealthReportsBrokenInputs(t *testing.T) {
	root := t.TempDir()
	if _, err := ReadModelHealthFile(ModelHealthPath(root), time.Now()); !errors.Is(err, ErrNoModelHealth) {
		t.Errorf("missing file error = %v, want ErrNoModelHealth", err)
	}

	empty := writeHealthFile(t, root, "   ")
	if _, err := ReadModelHealthFile(empty, time.Now()); !errors.Is(err, ErrNoModelHealth) {
		t.Errorf("empty file error = %v, want ErrNoModelHealth", err)
	}

	broken := writeHealthFile(t, root, "{not json")
	if _, err := ReadModelHealthFile(broken, time.Now()); err == nil || errors.Is(err, ErrNoModelHealth) {
		t.Errorf("broken file error = %v, want a parse error", err)
	}
}

func TestRecommendCoversProxyAndBreaker(t *testing.T) {
	health := []ModelHealth{{Model: "m", Open: true, OpenUntil: "2099-01-01T00:00:00"}}

	down := Recommend(ProxyResult{Address: DefaultProxyAddress, Status: StatusProxyDown}, health, nil)
	if len(down) < 2 {
		t.Fatalf("recommendations = %v, want proxy and breaker guidance", down)
	}
	joined := down[0] + " " + down[1]
	if !strings.Contains(joined, "DOWN") || !strings.Contains(joined, "breaker OPEN") {
		t.Errorf("recommendations = %v, want the proxy failure and the open breaker named", down)
	}

	missing := Recommend(ProxyResult{Address: DefaultProxyAddress, Status: StatusOK}, nil, ErrNoModelHealth)
	if !strings.Contains(missing[len(missing)-1], "model-router.ps1 -Probe") {
		t.Errorf("recommendations = %v, want the -Probe hint for a missing health state", missing)
	}
}

func TestIsBreakerOpen(t *testing.T) {
	now := time.Date(2026, 9, 18, 12, 0, 0, 0, time.Local)
	if !IsBreakerOpen("2026-09-18T12:30:00", now) {
		t.Error("a future open_until must be open")
	}
	if IsBreakerOpen("2026-09-18T11:30:00", now) {
		t.Error("a past open_until must be closed")
	}
	if IsBreakerOpen("", now) || IsBreakerOpen("garbage", now) {
		t.Error("empty/unparsable open_until must be closed")
	}
}
