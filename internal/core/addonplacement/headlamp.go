// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addonplacement

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func FindHeadlampChart(chartDir string) (string, error) {
	charts, err := filepath.Glob(filepath.Join(chartDir, "headlamp-*.tgz"))
	if err != nil || len(charts) != 1 {
		return "", fmt.Errorf("expected exactly one bundled Headlamp chart in %s", chartDir)
	}
	return charts[0], nil
}

func PrepareHeadlampChart(chartDir, selector string) (string, []byte, error) {
	chart, err := FindHeadlampChart(chartDir)
	if err != nil {
		return "", nil, err
	}
	values, err := os.ReadFile(filepath.Join(chartDir, "values.yaml"))
	if err != nil {
		return "", nil, err
	}
	values, err = RenderHelmValues(values, selector)
	return chart, values, err
}

func TemplateHeadlampChart(executable, chart string, values []byte) ([]byte, error) {
	file, err := os.CreateTemp("", "k2s-headlamp-template-values-*.yaml")
	if err != nil {
		return nil, err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(values)
	closeErr := file.Close()
	if writeErr != nil {
		return nil, writeErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	command := exec.Command(executable, "template", "headlamp", chart, "--namespace", "dashboard", "--values", file.Name())
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("render offline Headlamp chart: %w: %s", err, strings.TrimSpace(stderr.String()+"\n"+string(output)))
	}
	return output, nil
}
