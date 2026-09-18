// Package worktree owns the per-project isolation boundary of agent-hq: a git
// worktree, the canonical per-project CONTEXT-BUFFER.md path and a guarded
// writer that refuses cross-project writes.
//
// The package mirrors .agents/scripts/project-worktree.ps1 (P1-2) so the Go
// control plane and the PowerShell tooling operate on the same layout:
//
//	<root>/projects/<name>/CONTEXT-BUFFER.md   canonical project buffer
//	<root>/.agents/worktrees/<name>            worktree on branch project/<name>
//
// ValidateName is the Go twin of Test-ProjectName: the same whitelist (Unicode
// letters and digits, '_', '-', single spaces), the same rejection of path
// separators, Windows-invalid characters, reserved device names and names
// longer than 63 characters. A name the PowerShell helper accepts is accepted
// here and vice versa.
package worktree

import (
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// MaxNameLength is the longest accepted project name, counted in runes. It
// matches $ProjectNameMaxLength in project-worktree.ps1 (63 characters).
const MaxNameLength = 63

// reservedNames lists the Windows device names that may never be used as a
// directory component. The lookup is case-insensitive.
var reservedNames = map[string]struct{}{
	"CON":  {},
	"PRN":  {},
	"AUX":  {},
	"NUL":  {},
	"COM1": {},
	"COM2": {},
	"COM3": {},
	"COM4": {},
	"COM5": {},
	"COM6": {},
	"COM7": {},
	"COM8": {},
	"COM9": {},
	"LPT1": {},
	"LPT2": {},
	"LPT3": {},
	"LPT4": {},
	"LPT5": {},
	"LPT6": {},
	"LPT7": {},
	"LPT8": {},
	"LPT9": {},
}

// ValidateName reports whether name is a safe project identifier. It never
// panics and returns a human-readable error suitable for a CLI message.
func ValidateName(name string) error {
	if strings.TrimSpace(name) == "" {
		return errors.New("name is empty or whitespace")
	}
	if utf8.RuneCountInString(name) > MaxNameLength {
		return fmt.Errorf("name is longer than %d characters", MaxNameLength)
	}

	for index, symbol := range name {
		if index == 0 && !isNameLetterOrDigit(symbol) {
			return errors.New("the name must start with a letter or a digit")
		}
		if isNameLetterOrDigit(symbol) || symbol == '_' || symbol == '-' || symbol == ' ' {
			continue
		}
		return errors.New("only letters (any language), digits, '_', '-' and single spaces are allowed; " +
			"the name must not contain / \\ . : * ? \" < > |")
	}

	// The character class accepts a space before the end anchor and two spaces
	// in a row; the contract promises single spaces only.
	if strings.Contains(name, "  ") {
		return errors.New("only single spaces are allowed (consecutive spaces found)")
	}
	// A dot is not an accepted character at all, so this is belt-and-braces:
	// it mirrors the explicit path-traversal guard of Test-ProjectName.
	if strings.Contains(name, "..") {
		return errors.New("'..' is not allowed (path traversal)")
	}
	if strings.HasSuffix(name, " ") || strings.HasSuffix(name, ".") {
		return errors.New("the name must not end with a space or a dot")
	}
	if _, reserved := reservedNames[strings.ToUpper(name)]; reserved {
		return fmt.Errorf("%q is a reserved Windows device name", name)
	}
	return nil
}

// AssertName wraps ValidateName with the project identifier, so callers get a
// single error that names the offending value.
func AssertName(project string) error {
	if err := ValidateName(project); err != nil {
		return fmt.Errorf("invalid project name %q: %w", project, err)
	}
	return nil
}

func isNameLetterOrDigit(symbol rune) bool {
	return unicode.IsLetter(symbol) || unicode.IsDigit(symbol)
}

// isRefSafeRune reports whether symbol may appear inside a git ref without
// percent-encoding.
func isRefSafeRune(symbol rune) bool {
	return unicode.IsLetter(symbol) || unicode.IsDigit(symbol) || symbol == '_' || symbol == '-'
}

// Branch returns the git branch of a project worktree. A git ref may not
// contain a space, so every rune that is not ref-safe is percent-encoded from
// its UTF-8 bytes; for a valid project name the only such rune is the space
// (encoded as %20), so the historical "project/<name>" form is preserved
// verbatim for names without spaces, Cyrillic included. Percent-encoding every
// unsafe rune (rather than replacing spaces only) keeps the mapping injective
// even when Branch is called with a name that ValidateName would reject.
func Branch(project string) string {
	var builder strings.Builder
	builder.WriteString("project/")
	for _, symbol := range project {
		if isRefSafeRune(symbol) {
			builder.WriteRune(symbol)
			continue
		}
		for _, encoded := range []byte(string(symbol)) {
			fmt.Fprintf(&builder, "%%%02X", encoded)
		}
	}
	return builder.String()
}
