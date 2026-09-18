package state

import (
	"fmt"
	"strings"
	"time"
)

// timeLayouts covers every timestamp shape the PowerShell tooling writes.
// Claims use "yyyy-MM-ddTHH:mm:ss.fff", evidence documents and bus messages use
// the round-trip "o" format, some older artifacts use bare dates.
var timeLayouts = []string{
	time.RFC3339Nano,
	time.RFC3339,
	"2006-01-02T15:04:05.000",
	"2006-01-02T15:04:05",
	"2006-01-02T15:04",
	"2006-01-02 15:04:05",
	"2006-01-02",
}

// ParseTime accepts any of the supported timestamp layouts. The boolean is
// false when the value is empty or unrecognized.
func ParseTime(value string) (time.Time, bool) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return time.Time{}, false
	}
	for _, layout := range timeLayouts {
		if parsed, err := time.Parse(layout, trimmed); err == nil {
			return parsed, true
		}
	}
	return time.Time{}, false
}

// FormatTime renders a timestamp in the canonical RFC3339 form, or "-" when
// the value is empty or unparsable.
func FormatTime(value string) string {
	parsed, ok := ParseTime(value)
	if !ok {
		if strings.TrimSpace(value) == "" {
			return "-"
		}
		return value
	}
	return parsed.Format(time.RFC3339)
}

// FormatAge renders a duration as a compact human-readable age ("3s", "5m12s",
// "2h3m", "4d1h").
func FormatAge(duration time.Duration) string {
	if duration < 0 {
		duration = 0
	}
	seconds := int64(duration.Seconds())
	days := seconds / 86400
	hours := (seconds % 86400) / 3600
	minutes := (seconds % 3600) / 60
	remaining := seconds % 60

	switch {
	case days > 0:
		return fmt.Sprintf("%dd%dh", days, hours)
	case hours > 0:
		return fmt.Sprintf("%dh%dm", hours, minutes)
	case minutes > 0:
		return fmt.Sprintf("%dm%ds", minutes, remaining)
	default:
		return fmt.Sprintf("%ds", remaining)
	}
}
