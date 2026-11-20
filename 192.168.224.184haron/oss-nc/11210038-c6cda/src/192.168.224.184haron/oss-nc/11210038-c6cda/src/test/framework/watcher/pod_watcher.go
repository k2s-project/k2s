// SPDX-FileCopyrightText: © 2025 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package watcher

import (
	"bufio"
	"context"
	"io"
	"os/exec"
	"strings"
	"time"
)

// PodWatcher monitors pod status changes in a Kubernetes namespace
type PodWatcher struct {
	cmd       *exec.Cmd
	cancel    context.CancelFunc
	logger    Logger
	namespace string
}

// Logger interface for flexible logging
type Logger interface {
	Println(args ...interface{})
	Printf(format string, args ...interface{})
}

// NewPodWatcher creates a new pod watcher instance
func NewPodWatcher(logger Logger, namespace string) *PodWatcher {
	return &PodWatcher{
		logger:    logger,
		namespace: namespace,
	}
}

// Start begins watching pods in the specified namespace
// kubectlPath should be the full path to the kubectl executable
func (pw *PodWatcher) Start(ctx context.Context, kubectlPath string) error {
	watchCtx, cancel := context.WithCancel(ctx)
	pw.cancel = cancel

	pw.logger.Println("Starting background pod watcher for namespace", pw.namespace)

	pw.cmd = exec.CommandContext(watchCtx, kubectlPath, "get", "pods", "-n", pw.namespace, "-o", "wide", "-w")

	// Create a pipe to capture stdout
	stdout, err := pw.cmd.StdoutPipe()
	if err != nil {
		pw.logger.Printf("Warning: failed to create stdout pipe for pod watcher: %v\n", err)
		return err
	}

	// Start the command
	if err := pw.cmd.Start(); err != nil {
		pw.logger.Printf("Warning: failed to start pod watcher: %v\n", err)
		return err
	}

	// Read output in a goroutine and write to logger
	go pw.readWatchOutput(watchCtx, stdout)

	pw.logger.Println("Pod watcher started successfully")
	return nil
}

// readWatchOutput continuously reads and logs pod watch output
func (pw *PodWatcher) readWatchOutput(ctx context.Context, stdout io.ReadCloser) {
	defer func() {
		if r := recover(); r != nil {
			pw.logger.Printf("Pod watcher goroutine panic: %v\n", r)
		}
	}()

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()
		pw.logger.Printf("[POD-WATCH] %s\n", line)
	}

	if err := scanner.Err(); err != nil && ctx.Err() == nil {
		pw.logger.Printf("Pod watcher scanner error: %v\n", err)
	}
}

// Stop gracefully stops the pod watcher process
func (pw *PodWatcher) Stop() {
	if pw.cancel != nil {
		pw.logger.Println("Stopping pod watcher...")
		pw.cancel()
		pw.cancel = nil
	}

	if pw.cmd != nil && pw.cmd.Process != nil {
		// Give it a moment to terminate gracefully
		time.Sleep(500 * time.Millisecond)

		// Force kill if still running
		if err := pw.cmd.Process.Kill(); err != nil && !strings.Contains(err.Error(), "already finished") {
			pw.logger.Printf("Warning: failed to kill pod watcher process: %v\n", err)
		}

		pw.cmd = nil
		pw.logger.Println("Pod watcher stopped")
	}
}

// IsRunning returns true if the watcher process is still running
func (pw *PodWatcher) IsRunning() bool {
	return pw.cmd != nil && pw.cmd.Process != nil
}
