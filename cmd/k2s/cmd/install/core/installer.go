// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/install/common"
	ic "github.com/k2s-project/k2s/cmd/k2s/cmd/install/config"
	"github.com/k2s-project/k2s/cmd/k2s/utils"

	cc "github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/version"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

type InstallConfigAccess interface {
	Load(kind ic.Kind, cmdFlags *pflag.FlagSet) (*ic.InstallConfig, error)
}

type Printer interface {
	Printfln(format string, m ...any)
	PrintWarning(m ...any)
}

type EffectiveInstallConfigSnapshot interface {
	Path() string
	Abort() error
	Commit() error
}

type Installer struct {
	InstallConfigAccess             InstallConfigAccess
	Printer                         Printer
	ExecutePsScript                 func(script string, writer output.StreamWriter) error
	GetVersionFunc                  func() version.Version
	GetPlatformFunc                 func() string
	GetInstallDirFunc               func() string
	LoadConfigFunc                  func(configDir string) (*config.K2sRuntimeConfig, error)
	MarkSetupAsCorruptedFunc        func(configDir string) error
	DeleteConfigFunc                func(configDir string) error
	StageEffectiveInstallConfigFunc func(configDir string, content []byte) (EffectiveInstallConfigSnapshot, error)
}

func (i *Installer) Install(
	kind ic.Kind,
	cCmd *cobra.Command,
	buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error),
	cmdSession cc.CmdSession,
) error {
	context := cCmd.Context().Value(cc.ContextKeyCmdContext).(*cc.CmdContext)
	configDir := context.Config().Host().K2sSetupConfigDir()

	runtimeConfig, err := i.LoadConfigFunc(configDir)

	if errors.Is(err, config.ErrSystemInCorruptedState) {
		return cc.CreateSystemInCorruptedStateCmdFailure()
	}
	if err != nil && !errors.Is(err, config.ErrSystemNotInstalled) {
		return err
	}
	if err == nil && runtimeConfig.InstallConfig().SetupName() != "" {
		return &cc.CmdFailure{
			Severity: cc.SeverityWarning,
			Code:     "system-already-installed",
			Message:  fmt.Sprintf("'%s' setup already installed, please uninstall with 'k2s uninstall' first and re-run the install command afterwards", runtimeConfig.InstallConfig().SetupName()),
		}
	}

	config, err := i.InstallConfigAccess.Load(kind, cCmd.Flags())
	if err != nil {
		return err
	}

	slog.Debug("Installing using normalized effective configuration")

	cmd, err := buildCmdFunc(config)
	if err != nil {
		return err
	}

	var snapshot EffectiveInstallConfigSnapshot
	if i.StageEffectiveInstallConfigFunc != nil {
		effectiveInstallConfig, err := json.MarshalIndent(config, "", "  ")
		if err != nil {
			return fmt.Errorf("failed to serialize effective install configuration: %w", err)
		}
		snapshot, err = i.StageEffectiveInstallConfigFunc(configDir, effectiveInstallConfig)
		if err != nil {
			return err
		}
		cmd += " -EffectiveInstallConfigPath " + utils.EscapeWithSingleQuotes(snapshot.Path())
	}

	slog.Debug("PS command created", "command", cmd)

	i.Printer.Printfln("🤖 Installing K2s '%s' %s in '%s' on %s", kind, i.GetVersionFunc(), i.GetInstallDirFunc(), i.GetPlatformFunc())

	errorTracker := common.NewErrorTracker()
	context.StdWriter().OnStdErr(errorTracker.Track)

	err = i.ExecutePsScript(cmd, context.StdWriter())
	if err != nil {
		if snapshot != nil {
			if abortErr := snapshot.Abort(); abortErr != nil {
				return fmt.Errorf("installation failed: %w; snapshot cleanup failed: %v", err, abortErr)
			}
		}

		// Check for pre-requisites first
		errorLine, found := errorTracker.PreRequisiteError()
		if found {
			i.Printer.PrintWarning("Prerequisite check failed,", errorLine)
			i.Printer.PrintWarning("Have a look at the pre-requisites 'https://github.com/k2s-project/k2s/blob/main/docs/op-manual/installing-k2s.md#prerequisites' and re-issue 'k2s install'")
			err = i.DeleteConfigFunc(configDir)
			if err != nil {
				slog.Debug("config file does not exist, nothing to do")
			}
			return nil
		}

		if errorTracker.ErrOccurred() {
			if err := i.MarkSetupAsCorruptedFunc(configDir); err != nil {
				return fmt.Errorf("error while marking setup as corrupted: %w", err)
			}
			return cc.CreateSystemInCorruptedStateCmdFailure()
		}
		return err
	}

	if snapshot != nil {
		if err := snapshot.Commit(); err != nil {
			return err
		}
	}

	cmdSession.Finish()

	return nil
}
