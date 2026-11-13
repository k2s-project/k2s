// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier:   MIT

package logging

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/host"
	kos "github.com/k2s-project/k2s/internal/os"
)

// LogRootEnvVar is the environment variable that overrides the configured log root directory.
// When set, it takes precedence over setup.json and cfg/config.json.
const LogRootEnvVar = "K2S_LOG_ROOT"

// setupJsonLogRootKey is the top-level key in setup.json holding the persisted log root.
const setupJsonLogRootKey = "LogRoot"

// k2sLogFileName is the global K2s log file name.
const k2sLogFileName = "k2s.log"

var (
	rootLogDirOnce  sync.Once
	rootLogDirValue string
)

// RootLogDir returns K2s' central log directory.
//
// Resolution order (first hit wins):
//  1. environment variable K2S_LOG_ROOT
//  2. setup.json -> LogRoot (persisted at install time, under K2sConfigDir())
//  3. cfg/config.json -> configDir.logs (build-time default; only when k2sInstallDir is discoverable)
//  4. <SystemDrive>:\var\log (legacy fallback)
//
// The result is environment-expanded and the directory is created if missing.
// Result is memoized; tests must reset via ResetRootLogDirCache.
func RootLogDir() string {
	rootLogDirOnce.Do(func() {
		rootLogDirValue = ensureLogDir(resolveRootLogDir())
	})
	return rootLogDirValue
}

// RootLogDirForInstallation resolves the log directory using an installation's
// persisted setup config and configured fallback.
func RootLogDirForInstallation(configDir, configuredLogsDir string) string {
	return ensureLogDir(resolveRootLogDirForInstallation(configDir, configuredLogsDir))
}

// ResetRootLogDirCache clears the memoized RootLogDir value. Intended for tests only.
func ResetRootLogDirCache() {
	rootLogDirOnce = sync.Once{}
	rootLogDirValue = ""
}

// GlobalLogFilePath returns K2s' global log file path
func GlobalLogFilePath() string {
	return filepath.Join(RootLogDir(), k2sLogFileName)
}

func resolveRootLogDir() string {
	return resolveRootLogDirForInstallation(host.K2sConfigDir(), "")
}

func resolveRootLogDirForInstallation(configDir, configuredLogsDir string) string {
	candidates := []func() string{
		readLogRootFromEnv,
		func() string { return readLogRootFromSetupJson(configDir) },
		func() string { return configuredLogsDir },
		readLogRootFromConfigJson,
	}
	for _, fn := range candidates {
		if v := fn(); v != "" {
			return expandPath(v)
		}
	}
	return filepath.Join(host.SystemDrive(), "var", "log")
}

func readLogRootFromEnv() string {
	return strings.TrimSpace(os.Getenv(LogRootEnvVar))
}

func readLogRootFromSetupJson(configDir string) string {
	if configDir == "" {
		return ""
	}
	path := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	return readJsonStringField(path, setupJsonLogRootKey)
}

func readLogRootFromConfigJson() string {
	if runtime.GOOS == "linux" {
		// cfg/config.json contains the Windows default (C:\var\log). Native
		// Linux installations use the standard host log directory instead.
		return "/var/log"
	}

	installDir := os.Getenv("K2S_INSTALL_DIR")
	if installDir == "" {
		// Best-effort fallback: try the executable's directory chain.
		if exe, err := os.Executable(); err == nil {
			installDir = findInstallDirFromExe(exe)
		}
	}
	if installDir == "" {
		return ""
	}
	path := filepath.Join(installDir, "cfg", "config.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var raw struct {
		ConfigDir struct {
			Logs string `json:"logs"`
		} `json:"configDir"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return ""
	}
	return strings.TrimSpace(raw.ConfigDir.Logs)
}

// findInstallDirFromExe walks up from the executable directory looking for cfg/config.json.
func findInstallDirFromExe(exe string) string {
	dir := filepath.Dir(exe)
	for i := 0; i < 6; i++ {
		if _, err := os.Stat(filepath.Join(dir, "cfg", "config.json")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
	return ""
}

func readJsonStringField(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		return ""
	}
	v, ok := m[key].(string)
	if !ok {
		return ""
	}
	return strings.TrimSpace(v)
}

func expandPath(p string) string {
	expanded := os.ExpandEnv(p)
	if strings.HasPrefix(expanded, "~") {
		if home, err := os.UserHomeDir(); err == nil {
			expanded = filepath.Join(home, strings.TrimPrefix(expanded, "~"))
		}
	}
	return filepath.Clean(expanded)
}

func ensureLogDir(p string) string {
	if p == "" {
		return p
	}
	_ = os.MkdirAll(p, fs.ModePerm)
	return p
}

// InitializeLogFile creates the log directory and file if not existing
// Returns the log file handle
// path - The log file path
func InitializeLogFile(path string) *os.File {
	dir := filepath.Dir(path)

	if err := os.MkdirAll(dir, fs.ModePerm); err != nil {
		panic(err)
	}

	var err error
	logFile, err := os.OpenFile(
		path,
		os.O_APPEND|os.O_CREATE|os.O_WRONLY,
		os.ModePerm,
	)
	if err != nil {
		panic(err)
	}

	return logFile
}

// SetVerbosity sets the given verbosity on the log level variable after successful parsing
func SetVerbosity(verbosity string, levelVar *slog.LevelVar) error {
	level, err := parseLevel(verbosity)
	if err != nil {
		return err
	}

	levelVar.Set(level)

	return nil
}

// LevelToLowerString stringifies the given log level.
// The result can be parsed back to slog.Level
func LevelToLowerString(level slog.Level) string {
	return strings.ToLower(level.String())
}

// ShortenSourceAttribute replaces the full source file path with the file name and removes the function completely since the source line number gets logged as well
func ShortenSourceAttribute(_ []string, attribute slog.Attr) slog.Attr {
	if attribute.Key == slog.SourceKey {
		source := attribute.Value.Any().(*slog.Source)
		source.File = filepath.Base(source.File)
		source.Function = ""
	}
	return attribute
}

// CleanLogDir removes all files in the given directory that are older than the given age
// It considers only files in the given directory, not in sub-directories
func CleanLogDir(dir string, maxFileAge time.Duration) error {
	files, err := kos.FilesInDir(dir)
	if err != nil {
		return fmt.Errorf("failed to list files in log dir '%s': %w", dir, err)
	}

	slog.Debug("Found file in dir", "count", len(files), "dir", dir)

	err = files.OlderThan(maxFileAge).JoinPathsWith(dir).Remove()
	if err != nil {
		return fmt.Errorf("failed to delete outdated files in log dir '%s': %w", dir, err)
	}
	return nil
}

// SetupDefaultFileLogger sets up the default slog logger to log to the given file, removing it first if it exists
func SetupDefaultFileLogger(logDir, logFileName string, level slog.Level, args ...any) (*os.File, error) {
	logFilePath := filepath.Join(logDir, logFileName)
	if kos.PathExists(logFilePath) {
		if err := kos.RemovePaths(logFilePath); err != nil {
			return nil, fmt.Errorf("cannot remove log file '%s': %s", logFilePath, err)
		}
	}

	logFile := InitializeLogFile(logFilePath)
	loggerOptions := &slog.HandlerOptions{Level: level}
	textHandler := slog.NewTextHandler(logFile, loggerOptions)
	logger := slog.New(textHandler).With(args...)

	slog.SetDefault(logger)

	return logFile, nil
}

func LogExecutionTime(start time.Time, functionName string) {
	duration := time.Since(start)

	slog.Info("Execution finished", "function", functionName, "duration", duration)
}

func parseLevel(input string) (slog.Level, error) {
	var level slog.Level

	if err := level.UnmarshalText([]byte(input)); err != nil {
		parsedLevel, intErr := strconv.Atoi(input)
		if intErr != nil {
			return level, fmt.Errorf("cannot convert '%s' to log level: %w", input, errors.Join(err, intErr))
		}
		level = slog.Level(parsedLevel)
	}

	return level, nil
}
