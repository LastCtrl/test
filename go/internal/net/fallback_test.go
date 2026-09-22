package net

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writePassport(t *testing.T, root, content string) string {
	t.Helper()
	path := PassportPath(root)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write passport: %v", err)
	}
	return path
}

func TestReadPassportModelsOrdersByCostTier(t *testing.T) {
	root := t.TempDir()
	path := writePassport(t, root, `{"version": 1, "models": {
	  "paid/model": {"cost_tier": "paid"},
	  "zzz/free":   {"cost_tier": "free"},
	  "aaa/free":   {"cost_tier": "free"},
	  "mystery":    {"cost_tier": "weird"}
	}}`)

	models, err := ReadPassportModels(path)
	if err != nil {
		t.Fatalf("ReadPassportModels: %v", err)
	}
	want := []string{"aaa/free", "zzz/free", "paid/model", "mystery"}
	if len(models) != len(want) {
		t.Fatalf("models = %v, want %v", models, want)
	}
	for index := range want {
		if models[index] != want[index] {
			t.Errorf("models = %v, want %v", models, want)
			break
		}
	}
}

func TestReadPassportModelsRejectsBrokenInputs(t *testing.T) {
	root := t.TempDir()
	if _, err := ReadPassportModels(PassportPath(root)); err == nil {
		t.Error("a missing passport must be an error")
	}
	broken := writePassport(t, root, "{not json")
	if _, err := ReadPassportModels(broken); err == nil {
		t.Error("a corrupt passport must be an error")
	}
	empty := writePassport(t, root, `{"version": 1, "models": {}}`)
	if _, err := ReadPassportModels(empty); err == nil {
		t.Error("a passport without models must be an error")
	}
}

func TestSelectFallbackSkipsCurrentAndOpen(t *testing.T) {
	now := time.Date(2026, 9, 18, 12, 0, 0, 0, time.Local)
	health := []ModelHealth{
		{Model: "b", Open: true, OpenUntil: "2026-09-18T12:30:00"},
	}
	candidates := []string{"a", "b", "c"}

	chosen, reason := SelectFallback("a", candidates, health, now)
	if chosen != "c" {
		t.Fatalf("chosen = %q (%s), want c (a is current, b is open)", chosen, reason)
	}

	chosen, reason = SelectFallback("", []string{"b"}, health, now)
	if chosen != "" || reason == "" {
		t.Fatalf("chosen = %q (%s), want no candidate with a reason", chosen, reason)
	}
}

func TestSelectFallbackDeduplicatesAndHandlesEmptyInput(t *testing.T) {
	now := time.Now()
	chosen, reason := SelectFallback("", []string{"a", " a ", "a", "b"}, nil, now)
	if chosen != "a" {
		t.Fatalf("chosen = %q (%s), want the first distinct candidate a", chosen, reason)
	}
	if chosen, _ := SelectFallback("", nil, nil, now); chosen != "" {
		t.Errorf("chosen = %q, want empty when no candidates exist", chosen)
	}
}
