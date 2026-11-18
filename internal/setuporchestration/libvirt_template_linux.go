// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package setuporchestration

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"text/template"

	"github.com/k2s-project/k2s/internal/host"
)

// loadLibvirtTemplate loads a libvirt XML template by name.
//
// It first checks for a user-customised version at <K2sConfigDir>/libvirt/<name>.
// If that file exists it is used, allowing operators to tweak VM or network
// definitions before installation. Otherwise the compiled-in (//go:embed)
// default is returned.
func loadLibvirtTemplate(name string, embeddedDefault string) (*template.Template, error) {
	return loadLibvirtTemplateFromDir(filepath.Join(host.K2sConfigDir(), "libvirt"), name, embeddedDefault)
}

func loadLibvirtTemplateFromDir(customDir string, name string, embeddedDefault string) (*template.Template, error) {
	customPath := filepath.Join(customDir, name)

	if data, err := os.ReadFile(customPath); err == nil {
		slog.Info("[Libvirt] Using custom template", "path", customPath)
		tmpl, err := template.New(name).Parse(string(data))
		if err != nil {
			return nil, fmt.Errorf("failed to parse custom template %s: %w", customPath, err)
		}
		return tmpl, nil
	}

	slog.Debug("[Libvirt] Using embedded default template", "name", name)
	tmpl, err := template.New(name).Parse(embeddedDefault)
	if err != nil {
		return nil, fmt.Errorf("failed to parse embedded template %s: %w", name, err)
	}
	return tmpl, nil
}
