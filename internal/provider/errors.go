// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import "errors"

// ErrNotSupported is returned when a provider method is not available on the
// current platform (e.g., Windows-only operations on Linux).
var ErrNotSupported = errors.New("operation not supported on this platform")

// NotSupportedError returns a formatted not-supported error with a reason.
func NotSupportedError(operation, reason string) error {
	return &UnsupportedOperationError{Operation: operation, Reason: reason}
}

// UnsupportedOperationError provides detailed information about why an
// operation is not available on the current platform.
type UnsupportedOperationError struct {
	Operation string
	Reason    string
}

func (e *UnsupportedOperationError) Error() string {
	return "'" + e.Operation + "' is not supported on this platform: " + e.Reason
}

func (e *UnsupportedOperationError) Is(target error) bool {
	return target == ErrNotSupported
}

// FailureSeverity mirrors the severity levels used by CLI command failures.
type FailureSeverity uint8

const (
	// SeverityWarning indicates a non-fatal command failure (exit code 1, yellow output).
	SeverityWarning FailureSeverity = 3
	// SeverityError indicates a fatal command failure (exit code 1, red output).
	SeverityError FailureSeverity = 4
)

// ProviderFailure represents a structured failure returned by a provider
// operation (deserialized from PowerShell structured output). It carries the
// same severity/code/message semantics as common.CmdFailure to ensure the
// main error handler can display the correct output.
type ProviderFailure struct {
	Severity          FailureSeverity
	Code              string
	Message           string
	SuppressCliOutput bool
}

func (f *ProviderFailure) Error() string {
	return f.Code + ": " + f.Message
}
