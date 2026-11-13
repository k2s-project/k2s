// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/utils/logging"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/definitions"
	bl "github.com/k2s-project/k2s/internal/logging"
	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"

	"github.com/pterm/pterm"
)

type FailureSeverity uint8
type ContextKey string

type Spinner interface {
	Stop() error
}

type TerminalPrinter interface {
	StartSpinner(m ...any) (any, error)
}

type CmdFailure struct {
	Severity          FailureSeverity `json:"severity"`
	Code              string          `json:"code"`
	Message           string          `json:"message"`
	SuppressCliOutput bool
}

type CmdResult struct {
	Failure *CmdFailure `json:"error"`
}

type PtermWriter struct {
	errorLineBuffer *bl.LogBuffer
	stdErrListeners []func(line string)
}

type CmdContext struct {
	config    *config.K2sConfig
	logger    *logging.Slogger
	providers *provider.Registry
	stdWriter output.ObservableStreamWriter
}

type CmdSession struct {
	start          time.Time
	cmdDisplayName string
}

const (
	ErrSystemNotInstalledMsg     = "You have not installed K2s setup yet, please start the installation with command 'k2s.exe install' first"
	ErrSystemInCorruptedStateMsg = "Errors occurred during K2s setup. K2s cluster is in corrupted state. Please uninstall and reinstall K2s cluster."
	ErrSystemNotRunningMsg       = "The system is stopped. Run 'k2s start' to start the system."

	SeverityWarning FailureSeverity = 3
	SeverityError   FailureSeverity = 4

	ContextKeyCmdContext ContextKey = "cmd-context"

	OutputFlagName      = "output"
	OutputFlagShorthand = "o"
	OutputFlagUsage     = "Show log in terminal"

	AdditionalHooksDirFlagName  = "additional-hooks-dir"
	AdditionalHooksDirFlagUsage = "Directory containing additional hooks to be executed"

	DeleteFilesFlagName      = "delete-files-for-offline-installation"
	DeleteFilesFlagShorthand = "d"
	DeleteFilesFlagUsage     = "After an online installation delete the files that are needed for an offline installation"

	ForceOnlineInstallFlagName      = "force-online-installation"
	ForceOnlineInstallFlagShorthand = "f"
	ForceOnlineInstallFlagUsage     = "Force the online installation"

	AutouseCachedVSwitchFlagName  = "autouse-cached-vswitch"
	AutouseCachedVSwitchFlagUsage = "Automatically utilizes the cached vSwitch 'cbr0' and 'KubeSwitch' for cluster connectivity through the host machine"

	CacheVSwitchFlagName  = "cache-vswitch"
	CacheVSwitchFlagUsage = "Cache vswitches 'cbr0' and 'KubeSwitch' for cluster connectivity through the host machine."

	IgnoreIfRunningFlagName  = "ignore-if-running"
	IgnoreIfRunningFlagShort = "i"
	IgnoreIfRunningFlagUsage = "Skip starting the K2s cluster if it is already running"

	NodeFlagName  = "node"
	NodeFlagUsage = "Name of a specific node to start/stop"
)

func NewPtermWriter() *PtermWriter {
	return &PtermWriter{
		errorLineBuffer: createErrorLineBuffer(),
	}
}

func NewCmdContext(config *config.K2sConfig, logger *logging.Slogger, providers *provider.Registry, stdWriter output.ObservableStreamWriter) *CmdContext {
	return &CmdContext{
		config:    config,
		logger:    logger,
		providers: providers,
		stdWriter: stdWriter,
	}
}

func StartCmdSession(cmdDisplayName string) CmdSession {
	slog.Debug("Command started", "command", cmdDisplayName)

	return CmdSession{
		start:          time.Now(),
		cmdDisplayName: cmdDisplayName,
	}
}

func CreateSystemNotInstalledCmdResult() CmdResult {
	return CmdResult{Failure: CreateSystemNotInstalledCmdFailure()}
}

func CreateSystemInCorruptedStateCmdResult() CmdResult {
	return CmdResult{Failure: CreateSystemInCorruptedStateCmdFailure()}
}

func CreateSystemNotInstalledCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityWarning,
		Code:     config.ErrSystemNotInstalled.Error(),
		Message:  ErrSystemNotInstalledMsg,
	}
}

func CreateSystemInCorruptedStateCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityError,
		Code:     config.ErrSystemInCorruptedState.Error(),
		Message:  ErrSystemInCorruptedStateMsg,
	}
}

func CreateSystemUnableToUpgradeCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityError,
		Code:     "unable-to-upgrade",
		Message:  "'k2s system upgrade' failed",
	}
}

func CreateSystemUnableToUpdateCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityError,
		Code:     "unable-to-update",
		Message:  "'k2s system update' failed",
	}
}

func CreateFuncUnavailableForLinuxOnlyCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityWarning,
		Code:     "functionality-not-available-for-linux-only",
		Message:  "This functionality is not available in Linux-only setup.",
	}
}

func CreateSystemNotRunningCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityWarning,
		Code:     "system-not-running",
		Message:  ErrSystemNotRunningMsg,
	}
}

func StartSpinner(printer TerminalPrinter) (Spinner, error) {
	startResult, err := printer.StartSpinner("Gathering information..")
	if err != nil {
		return nil, err
	}

	spinner, ok := startResult.(Spinner)
	if !ok {
		return nil, errors.New("could not start operation")
	}

	return spinner, nil
}

func StopSpinner(spinner Spinner) {
	if err := spinner.Stop(); err != nil {
		slog.Error("spinner stop", "error", err)
	}
}

func (c *CmdFailure) Error() string { return fmt.Sprintf("%s: %s", c.Code, c.Message) }

func (s CmdSession) Finish(suppressOutput ...bool) {
	slog.Debug("Command finished", "command", s.cmdDisplayName)

	if len(suppressOutput) > 0 && suppressOutput[0] {
		return
	}

	pterm.Success.Printfln("'%s' completed in %v", s.cmdDisplayName, time.Since(s.start))

	logHint := pterm.LightCyan(fmt.Sprintf("Please see '%s' for more information", bl.GlobalLogFilePath()))

	pterm.Println(logHint)
}

func (s FailureSeverity) String() string {
	switch s {
	case SeverityWarning:
		return "warning"
	case SeverityError:
		return "error"
	default:
		return "unknown"
	}
}

func (w *PtermWriter) WriteStdOut(line string) {
	if strings.TrimSpace(line) == "" {
		return
	}
	pterm.Printfln("⏳ %s", line)
}

func (w *PtermWriter) WriteStdErr(line string) {
	w.errorLineBuffer.Log(line)
	for _, listener := range w.stdErrListeners {
		listener(line)
	}

	pterm.Printfln("⏳ %s", pterm.Yellow(line))
}

// OnStdErr registers a listener that is called for each stderr line.
func (w *PtermWriter) OnStdErr(listener func(line string)) {
	w.stdErrListeners = append(w.stdErrListeners, listener)
}

func (w *PtermWriter) Flush() { w.errorLineBuffer.Flush() }

func (c *CmdContext) Config() *config.K2sConfig { return c.config }

func (c *CmdContext) Logger() *logging.Slogger { return c.logger }

func (c *CmdContext) Providers() *provider.Registry { return c.providers }

func (c *CmdContext) StdWriter() output.ObservableStreamWriter { return c.stdWriter }

func (c *CmdContext) EnsureK2sK8sContext(clusterName string) error {
	slog.Debug("Ensuring correct K8s context", "cluster-name", clusterName)

	kubeConfigPath := filepath.Join(c.config.Host().KubeConfig().CurrentDir(), kubeconfig.DefaultFileName)
	if runtime.GOOS == "linux" {
		if _, err := os.Stat(kubeConfigPath); errors.Is(err, os.ErrNotExist) {
			const adminConfig = "/etc/kubernetes/admin.conf"
			if _, adminErr := os.Stat(adminConfig); adminErr == nil {
				slog.Debug("Falling back to admin kubeconfig", "path", adminConfig)
				kubeConfigPath = adminConfig
			}
		}
		if os.Getenv("KUBECONFIG") == "" {
			_ = os.Setenv("KUBECONFIG", kubeConfigPath)
		}
	}

	kubeConfig, err := kubeconfig.FromFile(kubeConfigPath)
	if err != nil {
		return fmt.Errorf("could not read kubeconfig: %w", err)
	}

	context, err := kubeConfig.FindContextByCluster(clusterName)
	if err != nil && clusterName != definitions.LegacyClusterName {
		if legacyContext, legacyErr := kubeConfig.FindContextByCluster(definitions.LegacyClusterName); legacyErr == nil {
			slog.Debug("Falling back to legacy cluster context", "cluster-name", definitions.LegacyClusterName)
			context = legacyContext
			err = nil
		}
	}
	if err != nil {
		return fmt.Errorf("could not find context for cluster '%s': %w", clusterName, err)
	}

	if context.Name == kubeConfig.CurrentContext {
		slog.Debug("K2s K8s context set as current context")
		return nil
	}

	message := fmt.Sprintf("This operation requires the K8s context '%s' to be set as current context.\nTo set the required context, run 'kubectl config use-context %s' and try again.", context.Name, context.Name)

	return &CmdFailure{
		Severity: SeverityWarning,
		Code:     "not-k2s-context",
		Message:  message,
	}
}

func createErrorLineBuffer() *bl.LogBuffer {
	return bl.NewLogBuffer(bl.BufferConfig{
		FlushFunc: func(buffer []string) {
			slog.Error("Flushing error lines", "count", len(buffer), "lines", buffer)
		},
	})
}
