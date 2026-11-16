// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

// Package healthcheck provides read-only diagnostic checks for a K2s host.
//
// A check inspects one known failure cause (e.g. low disk space or an expiring
// certificate) and reports whether it passed, needs attention or failed, along
// with a hint on how to fix it. Checks never modify the system.
package healthcheck

import "log/slog"

// Status is the outcome of a single check.
type Status string

const (
	// StatusPass means no problem was found.
	StatusPass Status = "pass"
	// StatusWarn means a problem was found that may cause issues soon.
	StatusWarn Status = "warn"
	// StatusFail means a problem was found that is likely to break the cluster.
	StatusFail Status = "fail"
	// StatusSkip means the check does not apply to this setup or could not be evaluated.
	StatusSkip Status = "skip"
)

// Result is the outcome of a single check.
type Result struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Status      Status `json:"status"`
	Message     string `json:"message"`
	Hint        string `json:"hint,omitempty"`
}

// Check is a single, named diagnostic check.
type Check struct {
	// Name is a stable, machine-readable identifier (e.g. 'host-disk-space').
	Name string
	// Description is a short, human-readable title.
	Description string
	// Run evaluates the check. It must not modify the system.
	Run func() Outcome
}

// Outcome is what a check's Run function returns.
type Outcome struct {
	Status  Status
	Message string
	Hint    string
}

// Report contains the results of all checks in execution order.
type Report struct {
	Results []Result `json:"results"`
}

// Run executes the given checks sequentially and collects their results.
func Run(checks []Check) Report {
	results := make([]Result, 0, len(checks))
	for _, check := range checks {
		outcome := check.Run()

		slog.Debug("Health check finished", "name", check.Name, "status", outcome.Status, "message", outcome.Message)

		results = append(results, Result{
			Name:        check.Name,
			Description: check.Description,
			Status:      outcome.Status,
			Message:     outcome.Message,
			Hint:        outcome.Hint,
		})
	}
	return Report{Results: results}
}

// HasFailures returns true if at least one check failed.
func (r Report) HasFailures() bool {
	return r.Count(StatusFail) > 0
}

// Count returns the number of results with the given status.
func (r Report) Count(status Status) int {
	count := 0
	for _, result := range r.Results {
		if result.Status == status {
			count++
		}
	}
	return count
}

func pass(message string) Outcome {
	return Outcome{Status: StatusPass, Message: message}
}

func warn(message, hint string) Outcome {
	return Outcome{Status: StatusWarn, Message: message, Hint: hint}
}

func fail(message, hint string) Outcome {
	return Outcome{Status: StatusFail, Message: message, Hint: hint}
}

func skip(message string) Outcome {
	return Outcome{Status: StatusSkip, Message: message}
}

// NewSkippedCheck returns a copy of the given check that reports itself as skipped
// with the given reason instead of running, e.g. when it does not apply to the setup.
func NewSkippedCheck(check Check, reason string) Check {
	return Check{
		Name:        check.Name,
		Description: check.Description,
		Run: func() Outcome {
			return skip(reason)
		},
	}
}
