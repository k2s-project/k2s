// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common

import "strings"

const preReqMarker = "[PREREQ-FAILED]"

type errorTracker struct {
	lines []string
}

func NewErrorTracker() *errorTracker {
	return &errorTracker{
		lines: []string{},
	}
}

// Track records a stderr line; it can be used as a stderr listener.
func (t *errorTracker) Track(line string) {
	t.lines = append(t.lines, line)
}

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
