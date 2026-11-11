// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package check

import (
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/healthcheck"
)

type checkPrinter interface {
	// Run executes the checks, e.g. while showing progress.
	Run(runFunc func() (healthcheck.Report, error)) (healthcheck.Report, error)
	// PrintReport prints the check results and returns a failure if at least one check failed.
	PrintReport(report healthcheck.Report) error
	// PrintSystemError prints a system state error that prevents the checks from running.
	PrintSystemError(systemError error, failure *common.CmdFailure) error
}

type TerminalPrinter interface {
	Println(m ...any)
	PrintHeader(m ...any)
	PrintGreenFg(text string) string
	PrintYellowFg(text string) string
	PrintRedFg(text string) string
	PrintCyanFg(text string) string
	StartSpinner(m ...any) (any, error)
}

type PrintCheck struct {
	Results []healthcheck.Result `json:"results"`
	Summary *PrintSummary        `json:"summary"`
	Error   *string              `json:"error"`
}

type PrintSummary struct {
	Passed   int `json:"passed"`
	Warnings int `json:"warnings"`
	Failed   int `json:"failed"`
	Skipped  int `json:"skipped"`
}

type JsonPrinter struct {
	printlnFunc       func(m ...any)
	marshalIndentFunc func(data any) ([]byte, error)
}

type UserFriendlyPrinter struct {
	terminalPrinter TerminalPrinter
}

func newJsonPrinter(printlnFunc func(m ...any), marshalIndentFunc func(data any) ([]byte, error)) *JsonPrinter {
	return &JsonPrinter{printlnFunc: printlnFunc, marshalIndentFunc: marshalIndentFunc}
}

func newUserFriendlyPrinter(terminalPrinter TerminalPrinter) *UserFriendlyPrinter {
	return &UserFriendlyPrinter{terminalPrinter: terminalPrinter}
}

func newPrintSummary(report healthcheck.Report) *PrintSummary {
	return &PrintSummary{
		Passed:   report.Count(healthcheck.StatusPass),
		Warnings: report.Count(healthcheck.StatusWarn),
		Failed:   report.Count(healthcheck.StatusFail),
		Skipped:  report.Count(healthcheck.StatusSkip),
	}
}

func (p *JsonPrinter) Run(runFunc func() (healthcheck.Report, error)) (healthcheck.Report, error) {
	return runFunc()
}

func (p *JsonPrinter) PrintReport(report healthcheck.Report) error {
	printCheck := PrintCheck{
		Results: report.Results,
		Summary: newPrintSummary(report),
	}

	var deferredErr error
	if report.HasFailures() {
		failure := createChecksFailedCmdFailure(report)
		failure.SuppressCliOutput = true
		printCheck.Error = &failure.Code
		deferredErr = failure
	}

	if err := p.print(printCheck); err != nil {
		return err
	}
	return deferredErr
}

func (p *JsonPrinter) PrintSystemError(systemError error, failure *common.CmdFailure) error {
	errCode := systemError.Error()
	if err := p.print(PrintCheck{Error: &errCode}); err != nil {
		return err
	}

	failure.SuppressCliOutput = true
	return failure
}

func (p *JsonPrinter) print(printCheck PrintCheck) error {
	bytes, err := p.marshalIndentFunc(printCheck)
	if err != nil {
		return err
	}

	checkJson := string(bytes)

	slog.Info("Printing", "json", checkJson)

	p.printlnFunc(checkJson)
	return nil
}

func (p *UserFriendlyPrinter) Run(runFunc func() (healthcheck.Report, error)) (healthcheck.Report, error) {
	spinner, err := common.StartSpinner(p.terminalPrinter)
	if err != nil {
		return healthcheck.Report{}, err
	}

	report, err := runFunc()

	common.StopSpinner(spinner)

	return report, err
}

func (p *UserFriendlyPrinter) PrintReport(report healthcheck.Report) error {
	p.terminalPrinter.PrintHeader("K2s SYSTEM CHECK")

	for _, result := range report.Results {
		p.terminalPrinter.Println(fmt.Sprintf("%s %s: %s", p.formatStatus(result.Status), result.Description, result.Message))
		if result.Hint != "" {
			p.terminalPrinter.Println(fmt.Sprintf("       %s %s", p.terminalPrinter.PrintCyanFg("Hint:"), result.Hint))
		}
	}

	summary := newPrintSummary(report)

	p.terminalPrinter.Println()
	p.terminalPrinter.Println(fmt.Sprintf("%d passed, %d warning(s), %d failed, %d skipped", summary.Passed, summary.Warnings, summary.Failed, summary.Skipped))

	if report.HasFailures() {
		return createChecksFailedCmdFailure(report)
	}
	return nil
}

func (p *UserFriendlyPrinter) PrintSystemError(_ error, failure *common.CmdFailure) error {
	return failure
}

func (p *UserFriendlyPrinter) formatStatus(status healthcheck.Status) string {
	switch status {
	case healthcheck.StatusPass:
		return p.terminalPrinter.PrintGreenFg("[PASS]")
	case healthcheck.StatusWarn:
		return p.terminalPrinter.PrintYellowFg("[WARN]")
	case healthcheck.StatusFail:
		return p.terminalPrinter.PrintRedFg("[FAIL]")
	default:
		return "[SKIP]"
	}
}
