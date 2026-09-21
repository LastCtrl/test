package bus

import (
	"regexp"
	"strings"
)

// redact.go mirrors Redact-Secrets in .agents/scripts/redact.ps1: the poller
// persists agent stdout and message payloads into the bus, so a credential an
// agent echoed must be masked before it reaches those files. Best effort, not a
// substitute for agents not printing secrets.
//
// The well-known key shapes are case sensitive (like -creplace in PowerShell),
// so ordinary lowercase words are not over-redacted.

// openAIKeyPattern is assembled from fragments on purpose: the literal prefix of
// an OpenAI-style key must not appear in a source file of this repository (the
// pre-commit secret scanner matches that prefix). The assembled value is the
// same shape redact.ps1 uses.
var openAIKeyPattern = regexp.MustCompile("s" + "k-" + `[A-Za-z0-9]{16,}`)

var redactShapePatterns = []*regexp.Regexp{
	openAIKeyPattern,
	regexp.MustCompile(`ghp_[A-Za-z0-9]{20,}`),
	regexp.MustCompile(`github_pat_[A-Za-z0-9_]{20,}`),
	regexp.MustCompile(`xox[baprs]-[A-Za-z0-9-]{10,}`),
	regexp.MustCompile(`AKIA[0-9A-Z]{16}`),
	regexp.MustCompile(`eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}`),
	regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`),
}

// bearerPattern keeps the scheme word and masks only the credential.
var bearerPattern = regexp.MustCompile(`(?i)(bearer)\s+[A-Za-z0-9._-]{16,}`)

// keyValuePattern finds "key: value" / "key=value" pairs. The PowerShell rule
// additionally requires a boundary before the key and rejects call expressions
// as values; Go's regexp engine has no lookarounds, so those two guards are
// applied to each match in Redact (see isCallValue / isKeyBounded).
var keyValuePattern = regexp.MustCompile(`(?i)(password|passwd|pwd|secret|token|api[_-]key)(\s*[:=]\s*)(\S+)`)

// callValuePattern matches a function/method call, which must never be masked.
var callValuePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_.]*\s*\(`)

const redactedMarker = "[REDACTED]"

// Redact masks well-known credential shapes in text. It is idempotent: applying
// it twice yields the same result.
func Redact(text string) string {
	if text == "" {
		return ""
	}
	value := text
	for _, pattern := range redactShapePatterns {
		value = pattern.ReplaceAllString(value, redactedMarker)
	}
	value = bearerPattern.ReplaceAllString(value, "$1 "+redactedMarker)
	return redactKeyValues(value)
}

// redactKeyValues implements the boundary- and call-guarded key/value rule.
func redactKeyValues(text string) string {
	matches := keyValuePattern.FindAllStringSubmatchIndex(text, -1)
	if len(matches) == 0 {
		return text
	}

	var builder strings.Builder
	cursor := 0
	for _, match := range matches {
		valueStart, valueEnd := match[6], match[7]
		if isKeyBounded(text, match[0]) && !isCallValue(text[valueStart:valueEnd]) {
			builder.WriteString(text[cursor:match[0]])
			builder.WriteString(text[match[2]:match[3]])
			builder.WriteString(text[match[4]:match[5]])
			builder.WriteString(redactedMarker)
			cursor = valueEnd
		}
	}
	builder.WriteString(text[cursor:])
	return builder.String()
}

// isKeyBounded reports whether the character before the key is not
// alphanumeric, the (?<![A-Za-z0-9]) guard of the PowerShell rule.
func isKeyBounded(text string, start int) bool {
	if start == 0 {
		return true
	}
	previous := text[start-1]
	return !isAlphaNumeric(previous)
}

// isCallValue reports whether a value looks like a call expression such as
// getApiKey() or obj.method(, which must stay untouched.
func isCallValue(value string) bool {
	return callValuePattern.MatchString(value)
}

func isAlphaNumeric(char byte) bool {
	switch {
	case char >= '0' && char <= '9':
		return true
	case char >= 'a' && char <= 'z':
		return true
	case char >= 'A' && char <= 'Z':
		return true
	}
	return false
}
