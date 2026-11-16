// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0
package tz

import (
	"embed"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/k2s-project/k2s/internal/contracts/config"
)

var (
	//go:embed embed/*.xml
	embeddedTimezoneConfig embed.FS
)

const (
	TimezoneConfigFile = "windowsZones.xml"
)

type ConfigWorkspace interface {
	CreateHandle() (ConfigWorkspaceHandle, error)
}

type ConfigWorkspaceHandle interface {
	Release() error
}

type fileHandler interface {
	CopyTo(newFile, originalFile string) error
	Remove(file string) error
}

type timezoneConfigHandler struct{}

type TimezoneConfigWorkspaceHandle struct {
	timezoneConfigFilePath string
	fileHandler            fileHandler
}

type TimezoneConfigWorkspace struct {
	kubeDir     string
	fileHandler fileHandler
}

func (tzch *timezoneConfigHandler) CopyTo(newFile, orginalFile string) error {
	embeddedFileContent, err := embeddedTimezoneConfig.ReadFile(orginalFile)
	if err != nil {
		return err
	}

	pathWithDirectoryOnly := filepath.Dir(newFile)
	err = os.MkdirAll(pathWithDirectoryOnly, fs.ModePerm)
	if err != nil {
		return err
	}

	// Copy the contents of the embedded file to the new file.
	err = os.WriteFile(newFile, []byte(embeddedFileContent), 0644)
	if err != nil {
		return err
	}

	return nil
}

func (tzch *timezoneConfigHandler) Remove(file string) error {
	err := os.Remove(file)
	if err != nil {
		return err
	}
	return nil
}

func NewTimezoneConfigWorkspace(config *config.KubeConfig) (ConfigWorkspace, error) {
	fileHandler := &timezoneConfigHandler{}

	return &TimezoneConfigWorkspace{
		kubeDir:     config.CurrentDir(),
		fileHandler: fileHandler,
	}, nil
}

func (tcws *TimezoneConfigWorkspace) CreateHandle() (ConfigWorkspaceHandle, error) {
	embeddedTzFp := "embed/" + TimezoneConfigFile
	tzFp := filepath.Join(tcws.kubeDir, TimezoneConfigFile)

	err := tcws.fileHandler.CopyTo(tzFp, embeddedTzFp)
	if err != nil {
		return nil, err
	}

	return &TimezoneConfigWorkspaceHandle{
		timezoneConfigFilePath: tzFp,
		fileHandler:            tcws.fileHandler,
	}, nil
}

func (tcwh *TimezoneConfigWorkspaceHandle) Release() error {
	err := tcwh.fileHandler.Remove(tcwh.timezoneConfigFilePath)
	if err != nil {
		return err
	}
	return nil
}
