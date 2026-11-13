// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package status

import (
	"errors"
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/contracts/config"

	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/primitives/arrays"
	"github.com/k2s-project/k2s/internal/primitives/units"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintCyanFg(text string) string
	PrintRedFg(text string) string
	PrintGreenFg(text string) string
	PrintHeader(m ...any)
	StartSpinner(m ...any) (any, error)
	PrintSuccess(m ...any)
	PrintInfoln(m ...any)
	PrintWarning(m ...any)
	PrintTreeListItems(items []string)
	PrintTableWithHeaders(table [][]string)
}

type Spinner interface {
	Stop() error
}

type JsonPrinter struct {
	basePrinter
	printlnFunc       func(m ...any)
	marshalIndentFunc func(data any) ([]byte, error)
}

type UserFriendlyPrinter struct {
	basePrinter
	showAdditionalInfo bool
	terminalPrinter    TerminalPrinter
}

type PrintStatus struct {
	SetupInfo      *PrintSetupInfo `json:"setupInfo"`
	RunningState   *RunningState   `json:"runningState"`
	Nodes          []Node          `json:"nodes"`
	Pods           []Pod           `json:"pods"`
	K8sVersionInfo *K8sVersionInfo `json:"k8sVersionInfo"`
	Error          *string         `json:"error"`
}

type PrintSetupInfo struct {
	Version   string `json:"version"`
	Name      string `json:"name"`
	LinuxOnly bool   `json:"linuxOnly"`
}

type basePrinter struct {
	config   *config.K2sRuntimeConfig
	loadFunc func() (*LoadedStatus, error)
}

func NewJsonPrinter(
	config *config.K2sRuntimeConfig,
	printlnFunc func(m ...any),
	marshalIndentFunc func(data any) ([]byte, error),
	loadFunc func() (*LoadedStatus, error)) *JsonPrinter {
	return &JsonPrinter{
		basePrinter: basePrinter{
			config:   config,
			loadFunc: loadFunc},
		printlnFunc:       printlnFunc,
		marshalIndentFunc: marshalIndentFunc,
	}
}

func NewUserFriendlyPrinter(
	config *config.K2sRuntimeConfig,
	showAdditionalInfo bool,
	terminalPrinter TerminalPrinter,
	loadFunc func() (*LoadedStatus, error)) *UserFriendlyPrinter {
	return &UserFriendlyPrinter{
		basePrinter: basePrinter{
			config:   config,
			loadFunc: loadFunc},
		showAdditionalInfo: showAdditionalInfo,
		terminalPrinter:    terminalPrinter,
	}
}

func (p *JsonPrinter) Print() error {
	loadedStatus, err := p.loadFunc()
	if err != nil {
		return err
	}

	printStatus := PrintStatus{
		SetupInfo: &PrintSetupInfo{
			Version:   p.config.InstallConfig().Version(),
			Name:      string(p.config.InstallConfig().SetupName()),
			LinuxOnly: p.config.InstallConfig().LinuxOnly(),
		},
		RunningState:   loadedStatus.RunningState,
		Nodes:          loadedStatus.Nodes,
		Pods:           loadedStatus.Pods,
		K8sVersionInfo: loadedStatus.K8sVersionInfo,
	}

	var deferredErr error
	if loadedStatus.Failure != nil {
		printStatus.Error = new(loadedStatus.Failure.Code)
		loadedStatus.Failure.SuppressCliOutput = true
		deferredErr = loadedStatus.Failure
	}

	slog.Info("Marshalling", "status", printStatus)

	bytes, err := p.marshalIndentFunc(printStatus)
	if err != nil {
		return err
	}

	statusJson := string(bytes)

	slog.Info("Printing", "json", statusJson)

	p.printlnFunc(statusJson)

	return deferredErr
}

func (p *UserFriendlyPrinter) Print() error {
	spinner, err := common.StartSpinner(p.terminalPrinter)
	if err != nil {
		return err
	}

	status, err := p.loadFunc()

	common.StopSpinner(spinner)

	if err != nil {
		return fmt.Errorf("status could not be loaded: %w", err)
	}

	if status.Failure != nil {
		return status.Failure
	}

	if status.RunningState == nil {
		return errors.New("no running state info retrieved")
	}

	p.terminalPrinter.PrintHeader("K2s SYSTEM STATUS")

	typeText := p.config.InstallConfig().SetupName()
	if p.config.InstallConfig().LinuxOnly() {
		typeText += " (Linux-only)"
	}

	printText := fmt.Sprintf("Setup: '%s', Version: '%s'", p.terminalPrinter.PrintCyanFg(typeText), p.terminalPrinter.PrintCyanFg(p.config.InstallConfig().Version()))

	p.terminalPrinter.Println(printText)

	if !status.RunningState.IsRunning {
		p.terminalPrinter.PrintInfoln(common.ErrSystemNotRunningMsg)
		p.terminalPrinter.PrintTreeListItems(status.RunningState.Issues)
		return nil
	}

	p.terminalPrinter.PrintSuccess("The system is running")

	if p.config.InstallConfig().SetupName() == definitions.SetupNameBuildOnlyEnv {
		slog.Debug("Setup type has no K8s components, skipping", "type", definitions.SetupNameBuildOnlyEnv)
		return nil
	}

	p.terminalPrinter.Println()

	if status.K8sVersionInfo == nil {
		return errors.New("no K8s version info retrieved")
	}

	p.printK8sVersion(status.K8sVersionInfo.K8sServerVersion, "server")
	p.printK8sVersion(status.K8sVersionInfo.K8sClientVersion, "client")

	_, err = p.printNodesStatus(status.Nodes, p.showAdditionalInfo)
	if err != nil {
		return fmt.Errorf("could not print node status: %w", err)
	}

	p.printPodsStatus(status.Pods, p.showAdditionalInfo)

	return nil
}

func (p *UserFriendlyPrinter) printK8sVersion(version string, versionType string) {
	versionText := p.terminalPrinter.PrintCyanFg(version)
	line := fmt.Sprintf("K8s %s version: '%s'", versionType, versionText)

	p.terminalPrinter.Println(line)
}

func (p *UserFriendlyPrinter) printNodesStatus(nodes []Node, showAdditionalInfo bool) (bool, error) {
	if len(nodes) == 0 {
		return false, nil
	}

	headers := createNodeHeaders(showAdditionalInfo)

	table := [][]string{headers}

	rows, allOkay, err := p.buildNodeRows(nodes, showAdditionalInfo)
	if err != nil {
		return false, fmt.Errorf("could not build node rows: %w", err)
	}

	table = append(table, rows...)

	p.terminalPrinter.PrintTableWithHeaders(table)

	if allOkay {
		p.terminalPrinter.PrintSuccess("All nodes are ready")
	} else {
		p.terminalPrinter.PrintWarning("Some nodes are not ready")
	}

	p.terminalPrinter.Println()

	return allOkay, nil
}

func (p *UserFriendlyPrinter) printPodsStatus(pods []Pod, showAdditionalInfo bool) {
	if len(pods) == 0 {
		return
	}

	headers := createPodHeaders(showAdditionalInfo)

	table := [][]string{headers}

	rows, allOkay := p.buildPodRows(pods, showAdditionalInfo)

	table = append(table, rows...)

	p.terminalPrinter.PrintTableWithHeaders(table)

	if allOkay {
		p.terminalPrinter.PrintSuccess("All essential Pods are running")
	} else {
		p.terminalPrinter.PrintWarning("Some essential Pods are not running")
	}

	p.terminalPrinter.Println()
}

func createNodeHeaders(showAdditionalInfo bool) []string {
	headers := []string{"STATUS", "NAME", "ROLE", "AGE", "VERSION", "CPUs", "RAM", "DISK"}

	if showAdditionalInfo {
		headers = append(headers, "INTERNAL-IP", "OS-IMAGE", "KERNEL-VERSION", "CONTAINER-RUNTIME")
	}

	return headers
}

func createPodHeaders(showAdditionalInfo bool) []string {
	headers := []string{"STATUS", "NAME", "READY", "RESTARTS", "AGE"}

	if showAdditionalInfo {
		headers = arrays.Insert(headers, "NAMESPACE", 1)
		headers = append(headers, "IP", "NODE")
	}

	return headers
}

func (p *UserFriendlyPrinter) buildNodeRows(nodes []Node, showAdditionalInfo bool) ([][]string, bool, error) {
	allOkay := true
	var rows [][]string

	for _, node := range nodes {
		row, err := p.buildNodeRow(node, showAdditionalInfo)
		if err != nil {
			return nil, false, fmt.Errorf("could not build node row: %w", err)
		}

		if !node.IsReady {
			allOkay = false
		}

		rows = append(rows, row)
	}

	return rows, allOkay, nil
}

func (p *UserFriendlyPrinter) buildPodRows(pods []Pod, showAdditionalInfo bool) ([][]string, bool) {
	allOkay := true
	var rows [][]string

	for _, pod := range pods {
		row := p.buildPodRow(pod, showAdditionalInfo)
		if !pod.IsRunning {
			allOkay = false
		}

		rows = append(rows, row)
	}

	return rows, allOkay
}

func (p *UserFriendlyPrinter) buildNodeRow(node Node, showAdditionalInfo bool) ([]string, error) {
	status := p.determineStatusColor(node.IsReady, node.Status)
	memory, err := units.ParseBase2Bytes(node.Capacity.Memory)
	if err != nil {
		return nil, fmt.Errorf("could not parse memory capacity: %w", err)
	}
	storage, err := units.ParseBase2Bytes(node.Capacity.Storage)
	if err != nil {
		return nil, fmt.Errorf("could not parse storage capacity: %w", err)
	}

	row := []string{status, node.Name, node.Role, node.Age, node.KubeletVersion, node.Capacity.Cpu, memory.String(), storage.String()}

	if showAdditionalInfo {
		row = append(row, node.InternalIp, node.OsImage, node.KernelVersion, node.ContainerRuntime)
	}

	return row, nil
}

func (p *UserFriendlyPrinter) buildPodRow(pod Pod, showAdditionalInfo bool) []string {
	status := p.determineStatusColor(pod.IsRunning, pod.Status)

	row := []string{status, pod.Name, pod.Ready, pod.Restarts, pod.Age}

	if showAdditionalInfo {
		row = arrays.Insert(row, pod.Namespace, 1)
		row = append(row, pod.Ip, pod.Node)
	}

	return row
}

func (p *UserFriendlyPrinter) determineStatusColor(isOkay bool, status string) string {
	if isOkay {
		return p.terminalPrinter.PrintGreenFg(status)
	}
	return p.terminalPrinter.PrintRedFg(status)
}
