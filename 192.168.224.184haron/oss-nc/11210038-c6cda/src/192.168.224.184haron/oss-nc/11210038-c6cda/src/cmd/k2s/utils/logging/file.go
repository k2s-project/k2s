// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package logging

import (
	"context"
	"fmt"
	"io"
	"log"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	base "github.com/k2s-project/k2s/internal/logging"
)

type FileHandler struct {
	logFile  *os.File
	writer   io.Writer
	levelVar *slog.LevelVar
	mu       sync.Mutex
	attrs    []slog.Attr
	groups   []string
}

const (
	componentAttributeName = "component"
	componentName          = "k2s.exe"
)

// NewFileHandler initializes the log file at the given path and creates an slog handler logging to this file
// in the same format as PowerShell's Write-Log:
// [dd-MM-yyyy HH:mm:ss] | Msg: <message> <key=value pairs> | From: [<file>:<line>](k2s.exe)
func NewFileHandler(filePath string) HandlerBuilder {
	return func(levelVar *slog.LevelVar) SlogHandler {
		logFile := base.InitializeLogFile(filePath)

		return &FileHandler{
			logFile:  logFile,
			writer:   logFile,
			levelVar: levelVar,
		}
	}
}

// Enabled reports whether the handler handles records at the given level.
func (h *FileHandler) Enabled(_ context.Context, level slog.Level) bool {
	return level >= h.levelVar.Level()
}

// Handle formats a log record in the PowerShell-compatible format and writes it to the log file.
func (h *FileHandler) Handle(_ context.Context, r slog.Record) error {
	timestamp := r.Time.Format("02-01-2006 15:04:05")

	// Build the message with extra attributes
	var extras []string
	// Add pre-set attrs first
	for _, a := range h.attrs {
		if a.Key == componentAttributeName {
			continue // handled in From: field
		}
		extras = append(extras, fmt.Sprintf("%s=%s", a.Key, a.Value.String()))
	}
	// Add record-level attrs
	r.Attrs(func(a slog.Attr) bool {
		extras = append(extras, fmt.Sprintf("%s=%s", a.Key, a.Value.String()))
		return true
	})

	msg := r.Message
	if len(extras) > 0 {
		msg = msg + " " + strings.Join(extras, " ")
	}

	// Source info
	source := ""
	if r.PC != 0 {
		fs := runtime.CallersFrames([]uintptr{r.PC})
		f, _ := fs.Next()
		if f.File != "" {
			source = fmt.Sprintf("[%s:%d](%s)", filepath.Base(f.File), f.Line, componentName)
		}
	}
	if source == "" {
		source = fmt.Sprintf("(%s)", componentName)
	}

	line := fmt.Sprintf("[%s] | Msg: %s | From: %s\n", timestamp, msg, source)

	h.mu.Lock()
	defer h.mu.Unlock()

	_, err := h.writer.Write([]byte(line))
	return err
}

// WithAttrs returns a new handler with the given attributes pre-set.
func (h *FileHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &FileHandler{
		logFile:  h.logFile,
		writer:   h.writer,
		levelVar: h.levelVar,
		attrs:    append(h.attrs, attrs...),
		groups:   h.groups,
	}
}

// WithGroup returns a new handler with the given group name.
func (h *FileHandler) WithGroup(name string) slog.Handler {
	return &FileHandler{
		logFile:  h.logFile,
		writer:   h.writer,
		levelVar: h.levelVar,
		attrs:    h.attrs,
		groups:   append(h.groups, name),
	}
}

// Flush writes pending changes to the log file
func (h *FileHandler) Flush() {
	if h.logFile == nil {
		return
	}

	if err := h.logFile.Sync(); err != nil {
		log.Fatal(err)
	}
}

// Close closes the log file and removes the file handle
func (h *FileHandler) Close() {
	if h.logFile == nil {
		return
	}

	if err := h.logFile.Close(); err != nil {
		log.Fatal(err)
	}

	h.logFile = nil
}
