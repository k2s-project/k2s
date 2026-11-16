// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package logging

import (
	"log/slog"
	"sync"
)

type BufferConfig struct {
	Limit     uint
	FlushFunc func(buffer []string)
}

type LogBuffer struct {
	buffer []string
	config BufferConfig
	lock   sync.Mutex
}

const DefaultBufferLimit uint = 100

func NewLogBuffer(config BufferConfig) *LogBuffer {
	if config.Limit == 0 {
		config.Limit = DefaultBufferLimit

		slog.Debug("Log buffer limit set to default", "value", DefaultBufferLimit)
	}
	if config.FlushFunc == nil {
		config.FlushFunc = func(_ []string) { /*stub*/ }

		slog.Debug("Log buffer flush func set to stub implementation")
	}

	return &LogBuffer{config: config}
}

func (e *LogBuffer) Log(line string) {
	e.lock.Lock()
	defer e.lock.Unlock()

	e.buffer = append(e.buffer, line)

	if len(e.buffer) >= int(e.config.Limit) {
		slog.Debug("Log buffer limit reached", "limit", e.config.Limit)

		e.flush()
	}
}

func (e *LogBuffer) Flush() {
	e.lock.Lock()
	defer e.lock.Unlock()

	if len(e.buffer) > 0 {
		e.flush()
	}
}

func (e *LogBuffer) flush() {
	slog.Debug("Flushing the buffer", "len", len(e.buffer))

	e.config.FlushFunc(e.buffer)

	e.buffer = nil
}
