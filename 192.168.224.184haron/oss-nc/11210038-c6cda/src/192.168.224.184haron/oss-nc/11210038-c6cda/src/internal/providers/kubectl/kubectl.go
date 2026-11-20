// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package kubectl

import (
	"fmt"
	"log/slog"
	"path/filepath"

	"github.com/k2s-project/k2s/internal/os"
)

type Kubectl struct {
	kubectlCmd string
}

func NewKubectl(rootDir string) *Kubectl {
	return &Kubectl{
		kubectlCmd: filepath.Join(rootDir, "bin", "kube", "kubectl.exe"),
	}
}

func (k *Kubectl) Exec(args ...string) error {
	slog.Debug("Executing kubectl command")

	cmd := os.NewCmd(k.kubectlCmd).
		WithArgs(args...).
		WithStdOutWriter(slog.Info).
		WithStdErrWriter(slog.Error)

	if err := cmd.Exec(); err != nil {
		return fmt.Errorf("failed to execute kubectl command: %w", err)
	}
	return nil
}
