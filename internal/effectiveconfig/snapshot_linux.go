// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package effectiveconfig

import "os"

func restrictFile(path string) error {
	return os.Chmod(path, restrictedFileMode)
}

func atomicReplace(source string, target string) error {
	return os.Rename(source, target)
}
