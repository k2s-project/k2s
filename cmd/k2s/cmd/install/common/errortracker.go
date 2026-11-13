// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common

import (
	"strings"

	"github.com/k2s-project/k2s/internal/output"
)

const preReqMarker = "[PREREQ-FAILED]"

// errorTracker is a StreamWriter decorator that records stderr lines while forwarding all output to the wrapped writer.
type errorTracker struct {
	writer output.StreamWriter
	lines  []string
}

func NewErrorTracker(writer output.StreamWriter) *errorTracker {
	return &errorTracker{
		writer: writer,
		lines:  []string{},
	}
}

func (t *errorTracker) WriteStdOut(message string) { t.writer.WriteStdOut(message) }

func (t *errorTracker) WriteStdErr(message string) {
	t.lines = append(t.lines, message)
	t.writer.WriteStdErr(message)
}

func (t *errorTracker) Flush() { t.writer.Flush() }

// ErrOccurred returns true if at least one stderr line was tracked.
func (t *errorTracker) ErrOccurred() bool {
	return len(t.lines) > 0
}

// PreRequisiteError returns the first tracked pre-requisite failure without its marker, if any.
func (t *errorTracker) PreRequisiteError() (line string, found bool) {
	for _, line := range t.lines {
		if !strings.Contains(line, preReqMarker) {
			continue
		}
		cleanedLine := strings.ReplaceAll(line, preReqMarker, "")
		cleanedLine = strings.Replace(cleanedLine, " ", "", 1)
		return cleanedLine, true
	}
	return "", false
}
