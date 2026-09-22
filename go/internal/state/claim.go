package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// DefaultLeaseSeconds mirrors the default lease written by the PowerShell task
// state helper.
const DefaultLeaseSeconds = 900

// Claim is one lease file .memory/claims/<name>.claim.json.
type Claim struct {
	TaskID       string `json:"task_id"`
	Agent        string `json:"agent"`
	ClaimedAt    string `json:"claimed_at"`
	HeartbeatAt  string `json:"heartbeat_at"`
	LeaseSeconds *int   `json:"lease_seconds"`
	Attempt      *int   `json:"attempt"`
	Path         string `json:"-"`
}

// AttemptValue returns the recorded attempt number, or 0.
func (c Claim) AttemptValue() int {
	if c.Attempt == nil {
		return 0
	}
	return *c.Attempt
}

// EffectiveTTL is the lease duration for this claim: its own lease_seconds
// when positive, otherwise DefaultLeaseSeconds.
func (c Claim) EffectiveTTL() time.Duration {
	if c.LeaseSeconds != nil && *c.LeaseSeconds > 0 {
		return time.Duration(*c.LeaseSeconds) * time.Second
	}
	return DefaultLeaseSeconds * time.Second
}

// ClaimStatus is a claim evaluated against its lease TTL.
type ClaimStatus struct {
	TaskID              string `json:"task_id"`
	Agent               string `json:"agent"`
	Attempt             int    `json:"attempt"`
	ClaimedAt           string `json:"claimed_at"`
	HeartbeatAt         string `json:"heartbeat_at"`
	TTLSeconds          int    `json:"ttl_seconds"`
	HeartbeatAgeSeconds int64  `json:"heartbeat_age_seconds"`
	Stale               bool   `json:"stale"`
	Reason              string `json:"reason"`
	Path                string `json:"path"`
}

// LoadClaims reads every lease file under <root>/.memory/claims. Only
// *.claim.json files are considered; attempt markers and temp files are
// ignored, matching the stale scan of the PowerShell task state helper.
func LoadClaims(root string) ([]Claim, []string) {
	dir := ClaimsDir(root)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, []string{fmt.Sprintf("claims: cannot list %s: %v", dir, err)}
	}

	claims := make([]Claim, 0, len(entries))
	var warnings []string

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".claim.json") {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("claims: cannot read %s: %v", path, err))
			continue
		}
		var claim Claim
		if err := json.Unmarshal(trimBOM(raw), &claim); err != nil {
			warnings = append(warnings, fmt.Sprintf("claims: broken json %s: %v", path, err))
			continue
		}
		claim.Path = path
		if strings.TrimSpace(claim.TaskID) == "" {
			claim.TaskID = strings.TrimSuffix(entry.Name(), ".claim.json")
		}
		claims = append(claims, claim)
	}

	sort.Slice(claims, func(i, j int) bool { return claims[i].TaskID < claims[j].TaskID })
	return claims, warnings
}

// EvaluateClaims ages every claim against its TTL. A lease whose heartbeat is
// older than the TTL (or cannot be parsed) is stale: this mirrors the
// Get-StaleClaims / Revoke-StaleClaims behaviour of the PowerShell task state
// helper, which treats an unreadable heartbeat as revocable. A positive
// ttlOverride replaces the per-claim lease duration for every claim.
func EvaluateClaims(claims []Claim, ttlOverride time.Duration, now time.Time) []ClaimStatus {
	statuses := make([]ClaimStatus, 0, len(claims))
	for _, claim := range claims {
		ttl := claim.EffectiveTTL()
		if ttlOverride > 0 {
			ttl = ttlOverride
		}

		status := ClaimStatus{
			TaskID:      claim.TaskID,
			Agent:       claim.Agent,
			Attempt:     claim.AttemptValue(),
			ClaimedAt:   claim.ClaimedAt,
			HeartbeatAt: claim.HeartbeatAt,
			TTLSeconds:  int(ttl.Seconds()),
			Path:        claim.Path,
			Reason:      "active",
		}

		heartbeat, ok := ParseTime(claim.HeartbeatAt)
		if !ok {
			status.Stale = true
			status.Reason = "unparsable-heartbeat"
			statuses = append(statuses, status)
			continue
		}

		age := now.Sub(heartbeat)
		if age < 0 {
			age = 0
		}
		status.HeartbeatAgeSeconds = int64(age.Seconds())
		if age > ttl {
			status.Stale = true
			status.Reason = "heartbeat-expired"
		}
		statuses = append(statuses, status)
	}
	return statuses
}
