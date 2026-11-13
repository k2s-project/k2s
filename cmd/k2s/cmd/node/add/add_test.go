// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package add

import (
	"context"
	"errors"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/status"
)

func TestLoadSystemStatusWithRetrySucceedsAfterTransientErrors(t *testing.T) {
	expected := &status.LoadedStatus{}
	attempts := 0

	actual, err := loadSystemStatusWithRetry(context.Background(), func() (*status.LoadedStatus, error) {
		attempts++
		if attempts < 3 {
			return nil, errors.New("API server unavailable")
		}
		return expected, nil
	}, 5, 0)

	if err != nil {
		t.Fatalf("loadSystemStatusWithRetry() error = %v", err)
	}
	if actual != expected {
		t.Fatalf("loadSystemStatusWithRetry() status = %p, want %p", actual, expected)
	}
	if attempts != 3 {
		t.Fatalf("loadSystemStatusWithRetry() attempts = %d, want 3", attempts)
	}
}

func TestLoadSystemStatusWithRetryReturnsLastError(t *testing.T) {
	firstErr := errors.New("first error")
	lastErr := errors.New("last error")
	attempts := 0

	_, err := loadSystemStatusWithRetry(context.Background(), func() (*status.LoadedStatus, error) {
		attempts++
		if attempts == 1 {
			return nil, firstErr
		}
		return nil, lastErr
	}, 3, 0)

	if !errors.Is(err, lastErr) {
		t.Fatalf("loadSystemStatusWithRetry() error = %v, want %v", err, lastErr)
	}
	if attempts != 3 {
		t.Fatalf("loadSystemStatusWithRetry() attempts = %d, want 3", attempts)
	}
}

func TestLoadSystemStatusWithRetryHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	attempts := 0

	_, err := loadSystemStatusWithRetry(ctx, func() (*status.LoadedStatus, error) {
		attempts++
		cancel()
		return nil, errors.New("API server unavailable")
	}, 5, systemStatusRetryDelay)

	if !errors.Is(err, context.Canceled) {
		t.Fatalf("loadSystemStatusWithRetry() error = %v, want %v", err, context.Canceled)
	}
	if attempts != 1 {
		t.Fatalf("loadSystemStatusWithRetry() attempts = %d, want 1", attempts)
	}
}
