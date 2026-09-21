package bus

import (
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// classify.go mirrors the result definition of inbox-engine.ps1. The Go CLI has
// its own executor markers (internal/executor) which are deliberately broader;
// the bus-level rule must be the PowerShell one, otherwise the same worker
// output would be classified differently by the two drivers.
//
// Differences that matter:
//   - the benign opencode subagent notice ("agent \"X\" not found. Falling back
//     to default agent") is removed BEFORE the error marker is matched, so it can
//     never turn a good run into a failure;
//   - the error marker list does not contain a bare "not found";
//   - a task whose message came from the interactive path (source=run|reply or
//     from=telegram) does not need a STATUS marker: exit 0 plus non-empty stdout
//     is the result.

var (
	// SuccessMarker matches the explicit success line of the prompt contract.
	SuccessMarker = regexp.MustCompile(`(?i)STATUS:\s*(resolved|done|completed)`)
	// ErrorMarker matches output that always means failure.
	ErrorMarker = regexp.MustCompile(`(?i)(permission denied|auto-rejecting|rejected permission|Error:|command not found|not recognized|no such file|cannot find path)`)
	// benignPatterns are removed before the error marker is evaluated.
	benignPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)agent\s+"[^"]*"\s+not found\.\s*Falling back to default agent`),
	}
	// TimeoutExitCode is the exit code the PowerShell engine reports for a killed
	// worker; the Go executor uses the same value.
	TimeoutExitCode = 124
)

// RemoveBenign strips the benign opencode warnings from text.
func RemoveBenign(text string) string {
	if text == "" {
		return ""
	}
	cleaned := text
	for _, pattern := range benignPatterns {
		cleaned = pattern.ReplaceAllString(cleaned, "")
	}
	return cleaned
}

// AttemptSucceeded applies the shared success rule: exit 0, non-empty stdout, no
// error marker in either stream and, when requireMarker is set, the success
// marker on stdout.
func AttemptSucceeded(exitCode int, stdout, stderr string, requireMarker bool) bool {
	if exitCode != 0 {
		return false
	}
	if strings.TrimSpace(stdout) == "" {
		return false
	}
	combined := RemoveBenign(stdout + "\n" + stderr)
	if ErrorMarker.MatchString(combined) {
		return false
	}
	if requireMarker && !SuccessMarker.MatchString(stdout) {
		return false
	}
	return true
}

// FailureReason renders the human-readable cause of a failed attempt, in the
// same order Get-AttemptFailureReason evaluates it.
func FailureReason(exitCode int, stdout, stderr string, requireMarker bool) string {
	if exitCode != 0 {
		return "exit code " + strconv.Itoa(exitCode)
	}
	if strings.TrimSpace(stdout) == "" {
		return "empty stdout"
	}
	combined := RemoveBenign(stdout + "\n" + stderr)
	if marker := ErrorMarker.FindString(combined); marker != "" {
		return "error marker in output: '" + marker + "'"
	}
	if requireMarker && !SuccessMarker.MatchString(stdout) {
		return "missing success marker '" + SuccessMarker.String() + "'"
	}
	return "unknown reason"
}

// LimitText truncates text to max characters and appends the same omission note
// as Limit-Text in inbox-engine.ps1. The ellipsis is written as an escape so
// this source file stays pure ASCII. Counting is per rune, which keeps multi-byte
// output valid JSON and matches the PowerShell character count for BMP text.
func LimitText(text string, max int) string {
	if max <= 0 {
		max = MaxResponseLength
	}
	total := utf8.RuneCountInString(text)
	if total <= max {
		return text
	}
	return cutRunes(text, max) + "\n\u2026[truncated " + strconv.Itoa(total-max) + " chars]"
}

// Truncate cuts text to max characters without a note; the outbox response is
// cut this way (Complete-InboxFile).
func Truncate(text string, max int) string {
	if max <= 0 {
		max = MaxResponseLength
	}
	if utf8.RuneCountInString(text) <= max {
		return text
	}
	return cutRunes(text, max)
}

// cutRunes returns the first max runes of text.
func cutRunes(text string, max int) string {
	count := 0
	for index := range text {
		if count == max {
			return text[:index]
		}
		count++
	}
	return text
}

// FormatAttemptReport renders one attempt for a dead-letter response, mirroring
// Format-AttemptReport in inbox-engine.ps1.
func FormatAttemptReport(reason string, exitCode int, stdout, stderr string) string {
	return "REASON: " + reason + "\n" +
		"EXIT CODE: " + strconv.Itoa(exitCode) + "\n" +
		"--- STDOUT ---\n" + LimitText(stdout, MaxResponseLength) + "\n" +
		"--- STDERR ---\n" + LimitText(stderr, MaxResponseLength)
}

// TimeoutMessage mirrors the stdout a killed PowerShell worker reports, so the
// stored evidence of a timeout looks the same for both drivers.
func TimeoutMessage(agent string, timeoutSeconds int) string {
	return "TIMEOUT: agent '" + agent + "' did not respond in " + strconv.Itoa(timeoutSeconds) + " seconds"
}

// NormalizeWorkerStdout mirrors the PowerShell capture of a child's stdout: the
// stream is read as an array of lines and rejoined with "\n", so line
// terminators never reach the stored hash, the recorded length or the outbox
// response (the PowerShell engine stores stderr raw, so it is not touched here).
func NormalizeWorkerStdout(text string) string {
	if text == "" {
		return ""
	}
	normalized := strings.ReplaceAll(text, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	lines := strings.Split(normalized, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return strings.Join(lines, "\n")
}
