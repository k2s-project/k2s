// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package host

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ResolveTildePrefixForCurrentUser replaces the leading tilde ('~') in the given path with the current user's home directory.
func ResolveTildePrefixForCurrentUser(path string) (string, error) {
	if !strings.HasPrefix(path, "~") {
		return path, nil
	}

	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to determine user home dir: %w", err)
	}
	return ResolveTildePrefix(path, homeDir), nil
}

// ResolveTildePrefix replaces the first tilde ('~') in the given path with the given path for replacement.
func ResolveTildePrefix(pathWithTilde, pathToReplaceTildeWith string) string {
	return filepath.Clean(strings.Replace(pathWithTilde, "~", pathToReplaceTildeWith, 1))
}
