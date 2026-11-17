// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package effectiveconfig

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/k2s-project/k2s/internal/definitions"
)

const restrictedFileMode os.FileMode = 0o600

type StagedSnapshot struct {
	path       string
	targetPath string
	configDir  string
}

func Stage(configDir string, content []byte) (*StagedSnapshot, error) {
	if len(content) == 0 {
		return nil, errors.New("effective install configuration is empty")
	}
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		return nil, fmt.Errorf("failed to create effective install configuration directory: %w", err)
	}

	file, err := os.CreateTemp(configDir, ".effective-install-config-*.tmp")
	if err != nil {
		return nil, fmt.Errorf("failed to stage effective install configuration: %w", err)
	}
	path := file.Name()
	removeOnError := true
	defer func() {
		if removeOnError {
			_ = os.Remove(path)
		}
	}()

	if err := file.Chmod(restrictedFileMode); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("failed to restrict staged effective install configuration: %w", err)
	}
	if _, err := file.Write(content); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("failed to write staged effective install configuration: %w", err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("failed to flush staged effective install configuration: %w", err)
	}
	if err := file.Close(); err != nil {
		return nil, fmt.Errorf("failed to close staged effective install configuration: %w", err)
	}
	if err := restrictFile(path); err != nil {
		return nil, err
	}

	removeOnError = false
	return &StagedSnapshot{
		path:       path,
		targetPath: filepath.Join(configDir, definitions.EffectiveInstallConfigFileName),
		configDir:  configDir,
	}, nil
}

func (s *StagedSnapshot) Path() string {
	return s.path
}

func (s *StagedSnapshot) Abort() error {
	if s.path == "" {
		return nil
	}
	if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("failed to remove staged effective install configuration: %w", err)
	}
	s.path = ""
	return nil
}

func (s *StagedSnapshot) Commit() error {
	previous, previousErr := os.ReadFile(s.targetPath)
	hadPrevious := previousErr == nil
	if previousErr != nil && !errors.Is(previousErr, os.ErrNotExist) {
		err := fmt.Errorf("failed to preserve previous effective install configuration: %w", previousErr)
		if abortErr := s.Abort(); abortErr != nil {
			return fmt.Errorf("%w; staged snapshot cleanup failed: %v", err, abortErr)
		}
		return err
	}

	if err := atomicReplace(s.path, s.targetPath); err != nil {
		commitErr := fmt.Errorf("failed to commit effective install configuration: %w", err)
		if abortErr := s.Abort(); abortErr != nil {
			return fmt.Errorf("%w; staged snapshot cleanup failed: %v", commitErr, abortErr)
		}
		return commitErr
	}
	s.path = ""

	if err := writeSetupLink(s.configDir, s.targetPath); err != nil {
		if rollbackErr := restorePrevious(s.targetPath, previous, hadPrevious); rollbackErr != nil {
			return fmt.Errorf("failed to link effective install configuration: %w; failed to restore previous snapshot: %v", err, rollbackErr)
		}
		return fmt.Errorf("failed to link effective install configuration: %w", err)
	}
	return nil
}

func writeSetupLink(configDir string, snapshotPath string) error {
	setupPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	content, err := os.ReadFile(setupPath)
	if err != nil {
		return err
	}

	var setup map[string]any
	if err := json.Unmarshal(content, &setup); err != nil {
		return err
	}
	setup[definitions.EffectiveInstallConfigPathKey] = snapshotPath

	updated, err := json.MarshalIndent(setup, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(setupPath, updated)
}

func restorePrevious(targetPath string, previous []byte, hadPrevious bool) error {
	if hadPrevious {
		return writeAtomic(targetPath, previous)
	}
	if err := os.Remove(targetPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func writeAtomic(targetPath string, content []byte) error {
	file, err := os.CreateTemp(filepath.Dir(targetPath), ".k2s-config-*.tmp")
	if err != nil {
		return err
	}
	path := file.Name()
	removeOnError := true
	defer func() {
		if removeOnError {
			_ = os.Remove(path)
		}
	}()

	if err := file.Chmod(restrictedFileMode); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := file.Write(content); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := restrictFile(path); err != nil {
		return err
	}
	if err := atomicReplace(path, targetPath); err != nil {
		return err
	}

	removeOnError = false
	return nil
}
