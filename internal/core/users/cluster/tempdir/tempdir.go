// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package tempdir

import (
	"fmt"
	"os"

	"github.com/k2s-project/k2s/internal/definitions"
)

func CreateTempDir() (string, error) {
	tempDir, err := os.MkdirTemp("", definitions.SetupNameK2s+"-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temporary directory: %w", err)
	}
	return tempDir, nil
}

func RemoveTempDir(tempDir string) error {
	err := os.RemoveAll(tempDir)
	if err != nil {
		return fmt.Errorf("failed to remove temporary directory: %w", err)
	}
	return nil
}
