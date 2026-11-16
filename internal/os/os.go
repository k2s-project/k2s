// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package os

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	bos "os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/k2s-project/k2s/internal/output"
)

type Files []fs.FileInfo
type Paths []string

type CmdExecutor struct {
	stdWriter output.StreamWriter
	ctx       context.Context
}

func ExecutableDir() (string, error) {
	exePath, err := bos.Executable()
	if err != nil {
		return "", fmt.Errorf("could not determine executable: %w", err)
	}
	return filepath.Dir(exePath), nil
}

func PathExists(path string) bool {
	_, err := bos.Stat(path)
	if err == nil {
		slog.Debug("Path exists", "path", path)
		return true
	}

	if !errors.Is(err, fs.ErrNotExist) {
		slog.Error("could not check existence of path", "path", path, "error", err)
	}
	return false
}

func RemovePaths(paths ...string) error {
	slog.Debug("Deleting paths", "paths", paths)

	for _, path := range paths {
		if err := bos.Remove(path); err != nil {
			return fmt.Errorf("could not remove '%s': %w", path, err)
		}
		slog.Debug("Path removed", "path", path)
	}
	return nil
}

func AppendToFile(path string, text string) error {
	file, err := bos.OpenFile(path, bos.O_APPEND|bos.O_WRONLY, bos.ModePerm)
	if err != nil {
		return fmt.Errorf("could not open file '%s': %w", path, err)
	}
	defer func() {
		if err := file.Close(); err != nil {
			slog.Error("could not close file", "path", path, "error", err)
		}
	}()

	if _, err = file.WriteString(text); err != nil {
		return fmt.Errorf("could not write to file '%s': %w", path, err)
	}
	return nil
}

func CopyFile(source string, target string) error {
	slog.Debug("Copying file", "source-path", source, "target-path", target)

	data, err := bos.ReadFile(source)
	if err != nil {
		return fmt.Errorf("could not read file '%s': %w", source, err)
	}

	if err = bos.WriteFile(target, data, bos.ModePerm); err != nil {
		return fmt.Errorf("could not write file '%s': %w", target, err)
	}
	return nil
}

// FilesInDir returns a list of files in the given directory.
// It does not check sub-directories (no recursion).
func FilesInDir(dir string) (files Files, err error) {
	paths, err := bos.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("could not read directory '%s': %w", dir, err)
	}

	for _, path := range paths {
		if path.IsDir() {
			continue
		}

		file, err := path.Info()
		if err != nil {
			return nil, fmt.Errorf("could not get file info '%s': %w", path.Name(), err)
		}
		files = append(files, file)
	}
	return files, nil
}

func NewCmdExecutor(stdWriter output.StreamWriter) *CmdExecutor { // TODO: use optional out and err writer std. interfaces + flush callback instead?
	return &CmdExecutor{stdWriter: stdWriter}
}

type stdWriter func(msg string, args ...any)

type cmdBuilder struct {
	cmd          string
	ctx          context.Context
	args         []string
	stdOutWriter stdWriter
	stdErrWriter stdWriter
}

var nilWriter stdWriter = func(msg string, args ...any) {}

func NewCmd(cmd string) *cmdBuilder {
	return &cmdBuilder{
		cmd:          cmd,
		args:         []string{},
		stdOutWriter: nilWriter,
		stdErrWriter: nilWriter,
	}
}

// TODO: add param guards
func (c *cmdBuilder) WithArgs(arg ...string) *cmdBuilder {
	c.args = append(c.args, arg...)
	return c
}

func (c *cmdBuilder) WithStdOutWriter(writer stdWriter) *cmdBuilder {
	c.stdOutWriter = writer
	return c
}

func (c *cmdBuilder) WithStdErrWriter(writer stdWriter) *cmdBuilder {
	c.stdErrWriter = writer
	return c
}

func (c *cmdBuilder) WithContext(ctx context.Context) *cmdBuilder {
	c.ctx = ctx
	return c
}

func (c *cmdBuilder) Exec() error {
	var cmd *exec.Cmd
	if c.ctx == nil {
		cmd = exec.Command(c.cmd, c.args...)
	} else {
		cmd = exec.CommandContext(c.ctx, c.cmd, c.args...)
	}

	cmd.Stdin = bos.Stdin
	stdOut, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}

	stdErr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}

	stdOutChan := make(chan string)
	stdErrChan := make(chan string)

	go readStream(stdOut, stdOutChan)
	go readStream(stdErr, stdErrChan)

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start command '%s': %w", c.cmd, err)
	}

	slog.Debug("Command started", "command", c.cmd)

	for stdOutChan != nil || stdErrChan != nil {
		select {
		case errMsg, ok := <-stdErrChan:
			if !ok {
				stdErrChan = nil

				slog.Debug("Channel closed", "channel", "stderr")
				continue
			}
			c.stdErrWriter(errMsg)
		case outMsg, ok := <-stdOutChan:
			if !ok {
				stdOutChan = nil

				slog.Debug("Channel closed", "channel", "stdout")
				continue
			}
			c.stdOutWriter(outMsg)
		}
	}

	slog.Debug("Waiting for command to finish", "command", c.cmd)

	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("command '%s' failed: %w", c.cmd, err)
	}

	slog.Debug("Command finished", "command", c.cmd)

	return nil
}

func (exe *CmdExecutor) WithContext(ctx context.Context) *CmdExecutor {
	exe.ctx = ctx
	return exe
}

// TODO: clone
func (exe *CmdExecutor) ExecuteCmd(name string, arg ...string) error {
	var cmd *exec.Cmd
	if exe.ctx == nil {
		cmd = exec.Command(name, arg...)
	} else {
		cmd = exec.CommandContext(exe.ctx, name, arg...)
	}

	cmd.Stdin = bos.Stdin
	stdOut, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}

	stdErr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}

	stdOutChan := make(chan string)
	stdErrChan := make(chan string)

	go readStream(stdOut, stdOutChan)
	go readStream(stdErr, stdErrChan)

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("command could not be started: %w", err)
	}

	slog.Debug("Command started")

	for stdOutChan != nil || stdErrChan != nil {
		select {
		case errMsg, ok := <-stdErrChan:
			if !ok {
				stdErrChan = nil

				slog.Debug("Channel closed", "channel", "stderr")
				continue
			}
			exe.stdWriter.WriteStdErr(errMsg)
		case stdMsg, ok := <-stdOutChan:
			if !ok {
				stdOutChan = nil

				slog.Debug("Channel closed", "channel", "stdout")
				continue
			}
			exe.stdWriter.WriteStdOut(stdMsg)
		}
	}

	exe.stdWriter.Flush()

	slog.Debug("Waiting for command to finish")

	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("command failed: %w", err)
	}

	slog.Debug("Command finished")

	return nil
}

func (files Files) OlderThan(duration time.Duration) (olderFiles Files) {
	for _, file := range files {
		if time.Since(file.ModTime()) > duration {
			olderFiles = append(olderFiles, file)
		}
	}
	return
}

func (files Files) JoinPathsWith(path string) (paths Paths) {
	for _, file := range files {
		paths = append(paths, filepath.Join(path, file.Name()))
	}
	return
}

func (paths Paths) Remove() error {
	return RemovePaths(paths...)
}

func readStream(stream io.ReadCloser, dataReceived chan string) {
	defer close(dataReceived)

	slog.Debug("routine started", "routine", "readStream")

	scanner := bufio.NewScanner(stream)

	for scanner.Scan() {
		dataReceived <- scanner.Text()
	}

	slog.Debug("routine finished", "routine", "readStream")
}
