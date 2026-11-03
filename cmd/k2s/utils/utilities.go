// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier:   MIT

package utils

import (
	"fmt"
	"log/slog"
	"runtime"
	"strings"

	"github.com/shirou/gopsutil/v3/host"
	"github.com/k2s-project/k2s/internal/os"

	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

var installDir string

func init() {
	var err error
	installDir, err = os.ExecutableDir()
	if err != nil {
		panic(err)
	}
}

func InstallDir() string {
	return installDir
}

// platform generates a user-readable platform message
func Platform() string {
	var s strings.Builder
	// Show the distro version if possible
	hi, err := host.Info()
	if err == nil {
		s.WriteString(fmt.Sprintf("%s %s", cases.Title(language.Und).String(hi.Platform), hi.PlatformVersion))
		slog.Debug("Host info", "info", hi)
	} else {
		slog.Warn("host.Info returned error", "error", err)
		s.WriteString(runtime.GOOS)
	}

	return s.String()
}

func FormatScriptFilePath(filePath string) string {
	return "&'" + filePath + "'"
}

func EscapeWithDoubleQuotes(str string) string {
	return "\"" + str + "\""
}

// powerShellSingleQuoteEscaper doubles every character PowerShell accepts as a single quote. Besides the
// ASCII apostrophe, PowerShell also treats the typographic quotes U+2018, U+2019, U+201A and U+201B as
// single-quote delimiters, so leaving any of them unescaped would terminate the quoted string early.
var powerShellSingleQuoteEscaper = strings.NewReplacer(
	"'", "''",
	"\u2018", "\u2018\u2018",
	"\u2019", "\u2019\u2019",
	"\u201A", "\u201A\u201A",
	"\u201B", "\u201B\u201B",
)

// EscapeWithSingleQuotes returns str as a PowerShell single-quoted (verbatim) string literal, so that
// PowerShell neither expands variables or sub-expressions in it nor treats any part of it as code.
func EscapeWithSingleQuotes(str string) string {
	return "'" + powerShellSingleQuoteEscaper.Replace(str) + "'"
}

// EscapeArrayWithSingleQuotes returns values as a comma-separated PowerShell array of single-quoted string literals.
func EscapeArrayWithSingleQuotes(values []string) string {
	escaped := make([]string, len(values))
	for i, value := range values {
		escaped[i] = EscapeWithSingleQuotes(value)
	}
	return strings.Join(escaped, ",")
}

// Escape $ in case of ssh cmd
func EscapeDollar(str string) string {
	return strings.ReplaceAll(str, "$", "```$")
}
