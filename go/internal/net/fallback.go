package net

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// PassportFileName is the P3 capability passport, relative to .agents/config.
const PassportFileName = "capability-passport.json"

// DefaultLadder mirrors $script:FallbackLadder in .agents/scripts/model-router.ps1
// (free checkers first, then the aihubmix endpoint, then the paid senior). It is
// the fallback source when the passport file is unavailable.
var DefaultLadder = []string{
	"opencode/ling-3.0-flash-fin-free",
	"opencode/mimo-v2.5-free",
	"opencode/big-pickle",
	"opencode/nemotron-3.5-lightning-free",
	"aihubmix/coding-glm-5.1-free",
	"aihubmix/gpt-5.5-free",
	"opencode-go/qwen3.8-flash",
}

// PassportPath returns <root>/.agents/config/capability-passport.json.
func PassportPath(root string) string {
	return filepath.Join(root, ".agents", "config", PassportFileName)
}

// costTierRank orders candidates the same way model-router.ps1 does: cheap
// first, unknown last.
var costTierRank = map[string]int{"free": 0, "medium": 1, "paid": 2, "unknown": 3}

// ReadPassportModels lists the passport's models, cheapest tier first and then
// alphabetically, so the fallback order is stable across runs. It is read-only.
func ReadPassportModels(path string) ([]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read passport %s: %w", path, err)
	}
	raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})

	var document struct {
		Models map[string]struct {
			CostTier string `json:"cost_tier"`
		} `json:"models"`
	}
	if err := json.Unmarshal(raw, &document); err != nil {
		return nil, fmt.Errorf("parse passport %s: %w", path, err)
	}
	if len(document.Models) == 0 {
		return nil, errors.New("passport has no models section")
	}

	type candidate struct {
		model string
		tier  int
	}
	candidates := make([]candidate, 0, len(document.Models))
	for model, entry := range document.Models {
		tier := costTierRank["unknown"]
		if rank, ok := costTierRank[strings.ToLower(strings.TrimSpace(entry.CostTier))]; ok {
			tier = rank
		}
		candidates = append(candidates, candidate{model: model, tier: tier})
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].tier != candidates[j].tier {
			return candidates[i].tier < candidates[j].tier
		}
		return candidates[i].model < candidates[j].model
	})

	models := make([]string, 0, len(candidates))
	for _, entry := range candidates {
		models = append(models, entry.model)
	}
	return models, nil
}

// MergeCandidates returns the passport's models (cheap tiers first) followed by
// the packaged ladder. A missing or broken passport is not fatal: the ladder is
// then the whole candidate list, which is exactly what model-router.ps1 does.
// Duplicates are collapsed by SelectFallback.
func MergeCandidates(passportPath string, ladder []string) []string {
	candidates := make([]string, 0, len(ladder))
	if passportModels, err := ReadPassportModels(passportPath); err == nil {
		candidates = append(candidates, passportModels...)
	}
	return append(candidates, ladder...)
}

// SelectFallback picks the first candidate that is neither the current model nor
// parked behind an open breaker. It returns an empty model plus a reason when
// nothing is viable, so the caller records why instead of guessing.
func SelectFallback(current string, candidates []string, health []ModelHealth, now time.Time) (string, string) {
	open := make(map[string]ModelHealth, len(health))
	for _, record := range health {
		if record.Open {
			open[record.Model] = record
		}
	}
	current = strings.TrimSpace(current)
	skippedOpen := make([]string, 0)
	seen := make(map[string]struct{}, len(candidates))

	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" || candidate == current {
			continue
		}
		if _, duplicate := seen[candidate]; duplicate {
			continue
		}
		seen[candidate] = struct{}{}
		if record, parked := open[candidate]; parked {
			skippedOpen = append(skippedOpen, fmt.Sprintf("%s (until %s)", record.Model, record.OpenUntil))
			continue
		}
		return candidate, "breaker closed for " + candidate
	}

	if len(skippedOpen) > 0 {
		return "", "every candidate is parked behind an open breaker: " + strings.Join(skippedOpen, ", ")
	}
	return "", "no fallback candidate configured"
}
