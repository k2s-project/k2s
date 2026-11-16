// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package os

import (
	bos "os"
	"path/filepath"
	"runtime"
	"strings"
)

// ExecutableFileName returns the platform-specific executable file name for the
// given base name, e.g. "k2s" -> "k2s.exe" on Windows and "k2s" on Linux.
func ExecutableFileName(baseName string) string {
	if runtime.GOOS == "windows" {
		return baseName + ".exe"
	}
	return baseName
}

// FindExecutablesInPath scans the process' PATH environment variable and returns
// the absolute paths of all existing files named exeName.
//
// Non-existing PATH entries are silently skipped. The returned slice preserves
// PATH order.
func FindExecutablesInPath(exeName string) ([]string, error) {
	pathEnv := bos.Getenv("PATH")
	if pathEnv == "" {
		return nil, nil
	}
	var found []string
	for _, dir := range filepath.SplitList(pathEnv) {
		if dir == "" || dir == "." {
			continue
		}
		exePath := filepath.Join(dir, exeName)
		absExePath, err := filepath.Abs(exePath)
		if err != nil {
			continue
		}
		if info, err := bos.Stat(absExePath); err == nil && !info.IsDir() {
			found = append(found, absExePath)
		}
	}
	return found, nil
}

// SamePath reports whether two paths denote the same file or directory, honoring the
// case-sensitivity semantics of the current platform: Windows paths are compared
// case-insensitively, paths on other platforms case-sensitively. Both paths are
// cleaned before comparison.
func SamePath(left string, right string) bool {
	left = filepath.Clean(left)
	right = filepath.Clean(right)

	if runtime.GOOS == "windows" {
		return strings.EqualFold(left, right)
	}
	return left == right
}

// FindOtherExecutablesInPath returns all executables named exeName found in PATH
// excluding the currently running executable (currentExe).
//
// The comparison honors the path case-sensitivity semantics of the current platform.
func FindOtherExecutablesInPath(currentExe string, exeName string) ([]string, error) {
	currentExeAbs, _ := filepath.Abs(currentExe)

	paths, err := FindExecutablesInPath(exeName)
	if err != nil {
		return nil, err
	}

	var others []string
	for _, path := range paths {
		absPath, _ := filepath.Abs(path)
		if !SamePath(absPath, currentExeAbs) {
			others = append(others, absPath)
		}
	}
	return others, nil
}

