package worktree

import (
	"strings"
	"testing"
)

// The accepted names cover ASCII, Cyrillic (both a Cyrillic word and a name
// that starts with a Cyrillic letter), a single space, '_' and '-'. All text is
// written with \u escapes: the Go sources must stay pure ASCII.
func TestValidateNameAccepts(t *testing.T) {
	valid := []string{
		"dev-2",
		"1c-centr1507",
		"1\u0441-centr1507",
		"\u043f\u0440\u043e\u0435\u043a\u0442",
		"\u041f\u0440\u043e\u0435\u043a\u0442 \u0410",
		"pro ject_1-2",
		strings.Repeat("a", MaxNameLength),
	}
	for _, name := range valid {
		if err := ValidateName(name); err != nil {
			t.Errorf("ValidateName(%q) = %v, want nil", name, err)
		}
	}
}

func TestValidateNameRejects(t *testing.T) {
	invalid := map[string]string{
		"empty":            "",
		"whitespace only":  "   ",
		"leading dash":     "-lead",
		"leading space":    " lead",
		"trailing space":   "trail ",
		"trailing dot":     "trail.",
		"slash":            "a/b",
		"backslash":        "a\\b",
		"dot":              "a.b",
		"colon":            "a:b",
		"star":             "a*b",
		"question mark":    "a?b",
		"angle open":       "a<b",
		"angle close":      "a>b",
		"pipe":             "a|b",
		"double quote":     "a\"b",
		"two spaces":       "a  b",
		"path traversal":   "..",
		"nested traversal": "..\\evil",
		"too long":         strings.Repeat("a", MaxNameLength+1),
		"reserved con":     "CON",
		"reserved con low": "con",
		"reserved nul":     "nul",
		"reserved com1":    "COM1",
		"reserved lpt9":    "LPT9",
	}
	for label, name := range invalid {
		if err := ValidateName(name); err == nil {
			t.Errorf("ValidateName(%q) [%s] = nil, want an error", name, label)
		}
	}
}

func TestAssertNameWrapsTheIdentifier(t *testing.T) {
	err := AssertName("../evil")
	if err == nil {
		t.Fatal("AssertName(traversal) = nil, want an error")
	}
	if !strings.Contains(err.Error(), "../evil") {
		t.Errorf("AssertName error = %q, want it to name the offending value", err.Error())
	}
}

func TestBranchKeepsNamesVerbatimWithoutSpaces(t *testing.T) {
	cases := map[string]string{
		"dev-2":                                "project/dev-2",
		"1\u0441-centr1507":                    "project/1\u0441-centr1507",
		"\u043f\u0440\u043e\u0435\u043a\u0442": "project/\u043f\u0440\u043e\u0435\u043a\u0442",
	}
	for project, want := range cases {
		if got := Branch(project); got != want {
			t.Errorf("Branch(%q) = %q, want %q", project, got, want)
		}
	}
}

func TestBranchPercentEncodesASpaceOnly(t *testing.T) {
	project := "\u041f\u0440\u043e\u0435\u043a\u0442 \u0410"
	want := "project/\u041f\u0440\u043e\u0435\u043a\u0442%20\u0410"
	if got := Branch(project); got != want {
		t.Errorf("Branch(%q) = %q, want %q", project, got, want)
	}
	// The mapping is injective because '%' cannot appear in a valid name.
	if ValidateName("a%b") == nil {
		t.Error("ValidateName(a percent b) = nil, want an error: the percent sign must stay reserved for encoding")
	}
	if Branch("a b") == Branch("a%20b") {
		t.Error("Branch mapping collided for two different names")
	}
}
