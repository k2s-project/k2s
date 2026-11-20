// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package check

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/healthcheck"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/pterm/pterm"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// fakeSystemProvider implements only Check; calling any other SystemProvider method panics.
type fakeSystemProvider struct {
	provider.SystemProvider
	report         healthcheck.Report
	err            error
	receivedConfig *provider.SystemCheckConfig
}

func (f *fakeSystemProvider) Check(config provider.SystemCheckConfig) (healthcheck.Report, error) {
	f.receivedConfig = &config
	return f.report, f.err
}

type fakeTerminalPrinter struct {
	lines []string
}

func (f *fakeTerminalPrinter) Println(m ...any) {
	if len(m) == 0 {
		f.lines = append(f.lines, "")
		return
	}
	f.lines = append(f.lines, m[0].(string))
}
func (f *fakeTerminalPrinter) PrintHeader(m ...any)               { f.Println(m...) }
func (f *fakeTerminalPrinter) PrintGreenFg(text string) string    { return text }
func (f *fakeTerminalPrinter) PrintYellowFg(text string) string   { return text }
func (f *fakeTerminalPrinter) PrintRedFg(text string) string      { return text }
func (f *fakeTerminalPrinter) PrintCyanFg(text string) string     { return text }
func (f *fakeTerminalPrinter) StartSpinner(m ...any) (any, error) { return &fakeSpinner{}, nil }

type fakeSpinner struct{}

func (*fakeSpinner) Stop() error { return nil }

func TestCheck(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system check Unit Tests", Label("unit", "ci"))
}

var mixedReport = healthcheck.Report{Results: []healthcheck.Result{
	{Name: "host-disk-space", Description: "Enough free disk space on the host", Status: healthcheck.StatusPass, Message: "C:\\: 50GiB free"},
	{Name: "apipa-address", Description: "No APIPA address", Status: healthcheck.StatusWarn, Message: "APIPA address found on 'Ethernet'", Hint: "renew the address"},
	{Name: "hyperv-vmms", Description: "Hyper-V service is running", Status: healthcheck.StatusFail, Message: "service 'vmms' is not running", Hint: "start the service"},
	{Name: "cluster-certificates", Description: "Cluster certificates are valid", Status: healthcheck.StatusSkip, Message: "not applicable"},
}}

var _ = Describe("system check", func() {
	Describe("runChecks", func() {
		var (
			setupDir     string
			kubeDir      string
			fakeProvider *fakeSystemProvider
			output       *bytes.Buffer
		)

		BeforeEach(func() {
			setupDir = GinkgoT().TempDir()
			kubeDir = GinkgoT().TempDir()
			fakeProvider = &fakeSystemProvider{}

			k2sConfig := config.NewK2sConfig(config.NewHostConfig(config.NewKubeConfig(kubeDir, "~/.kube", ""), nil, setupDir, "", ""), nil)
			cmdContext := common.NewCmdContext(k2sConfig, nil, &provider.Registry{System: fakeProvider})
			CheckCmd.SetContext(context.WithValue(context.TODO(), common.ContextKeyCmdContext, cmdContext))

			output = &bytes.Buffer{}
			pterm.SetDefaultOutput(output)
			DeferCleanup(func() {
				pterm.SetDefaultOutput(os.Stdout)
				Expect(CheckCmd.Flags().Set(outputFlagName, "")).To(Succeed())
			})
		})

		writeSetupConfig := func(content string) {
			Expect(os.WriteFile(filepath.Join(setupDir, "setup.json"), []byte(content), 0o600)).To(Succeed())
		}

		It("rejects unsupported output formats", func() {
			Expect(CheckCmd.Flags().Set(outputFlagName, "wide")).To(Succeed())

			err := runChecks(CheckCmd, nil)

			Expect(err).To(MatchError("parameter 'wide' not supported for flag 'o'"))
			Expect(fakeProvider.receivedConfig).To(BeNil())
		})

		When("the system is not installed", func() {
			It("returns the not-installed failure", func() {
				err := runChecks(CheckCmd, nil)

				var failure *common.CmdFailure
				Expect(errors.As(err, &failure)).To(BeTrue())
				Expect(failure.Code).To(Equal("system-not-installed"))
				Expect(failure.SuppressCliOutput).To(BeFalse())
				Expect(fakeProvider.receivedConfig).To(BeNil())
			})

			It("prints the error as JSON and suppresses the CLI error output", func() {
				Expect(CheckCmd.Flags().Set(outputFlagName, jsonOption)).To(Succeed())

				err := runChecks(CheckCmd, nil)

				var failure *common.CmdFailure
				Expect(errors.As(err, &failure)).To(BeTrue())
				Expect(failure.Code).To(Equal("system-not-installed"))
				Expect(failure.SuppressCliOutput).To(BeTrue())

				var printed PrintCheck
				Expect(json.Unmarshal(output.Bytes(), &printed)).To(Succeed())
				Expect(*printed.Error).To(Equal("system-not-installed"))
				Expect(printed.Results).To(BeNil())
			})
		})

		When("the system is in a corrupted state", func() {
			It("returns the corrupted-state failure", func() {
				writeSetupConfig(`{"SetupType": "k2s", "Corrupted": true}`)

				err := runChecks(CheckCmd, nil)

				var failure *common.CmdFailure
				Expect(errors.As(err, &failure)).To(BeTrue())
				Expect(failure.Code).To(Equal("system-in-corrupted-state"))
				Expect(fakeProvider.receivedConfig).To(BeNil())
			})
		})

		When("the system is installed", func() {
			BeforeEach(func() {
				writeSetupConfig(`{"SetupType": "k2s", "ClusterName": "k2s-cluster", "WSL": true, "LinuxOnly": true}`)
				Expect(CheckCmd.Flags().Set(outputFlagName, jsonOption)).To(Succeed())
			})

			It("passes the setup details to the provider", func() {
				fakeProvider.report = healthcheck.Report{Results: []healthcheck.Result{{Name: "a", Status: healthcheck.StatusPass}}}

				err := runChecks(CheckCmd, nil)

				Expect(err).ToNot(HaveOccurred())
				Expect(*fakeProvider.receivedConfig).To(Equal(provider.SystemCheckConfig{
					ClusterName:    "k2s-cluster",
					KubeconfigPath: filepath.Join(kubeDir, "config"),
					SetupName:      "k2s",
					LinuxOnly:      true,
					WslEnabled:     true,
				}))
			})

			It("prints the results as JSON and fails if a check failed", func() {
				fakeProvider.report = mixedReport

				err := runChecks(CheckCmd, nil)

				var failure *common.CmdFailure
				Expect(errors.As(err, &failure)).To(BeTrue())
				Expect(failure.Code).To(Equal(checkFailedCode))
				Expect(failure.Severity).To(Equal(common.SeverityError))
				Expect(failure.SuppressCliOutput).To(BeTrue())

				var printed PrintCheck
				Expect(json.Unmarshal(output.Bytes(), &printed)).To(Succeed())
				Expect(printed.Results).To(Equal(mixedReport.Results))
				Expect(*printed.Summary).To(Equal(PrintSummary{Passed: 1, Warnings: 1, Failed: 1, Skipped: 1}))
				Expect(*printed.Error).To(Equal(checkFailedCode))
			})

			It("returns provider errors", func() {
				fakeProvider.err = errors.New("oops")

				err := runChecks(CheckCmd, nil)

				Expect(err).To(MatchError("oops"))
				Expect(output.Len()).To(BeZero())
			})
		})
	})

	Describe("JsonPrinter", func() {
		It("prints a report without failures and returns no error", func() {
			var printed []string
			printer := newJsonPrinter(func(m ...any) { printed = append(printed, m[0].(string)) }, func(data any) ([]byte, error) {
				return json.Marshal(data)
			})

			err := printer.PrintReport(healthcheck.Report{Results: []healthcheck.Result{
				{Name: "a", Description: "A", Status: healthcheck.StatusPass, Message: "fine"},
				{Name: "b", Description: "B", Status: healthcheck.StatusWarn, Message: "hmm", Hint: "do x"},
			}})

			Expect(err).ToNot(HaveOccurred())
			Expect(printed).To(ConsistOf(`{"results":[{"name":"a","description":"A","status":"pass","message":"fine"},` +
				`{"name":"b","description":"B","status":"warn","message":"hmm","hint":"do x"}],` +
				`"summary":{"passed":1,"warnings":1,"failed":0,"skipped":0},"error":null}`))
		})

		It("returns marshalling errors", func() {
			printer := newJsonPrinter(func(m ...any) { Fail("must not print") }, func(any) ([]byte, error) {
				return nil, errors.New("marshal error")
			})

			Expect(printer.PrintReport(mixedReport)).To(MatchError("marshal error"))
		})
	})

	Describe("UserFriendlyPrinter", func() {
		It("prints every result with its hint and a summary and fails if a check failed", func() {
			terminalPrinter := &fakeTerminalPrinter{}
			printer := newUserFriendlyPrinter(terminalPrinter)

			report, err := printer.Run(func() (healthcheck.Report, error) { return mixedReport, nil })
			Expect(err).ToNot(HaveOccurred())

			err = printer.PrintReport(report)

			Expect(terminalPrinter.lines).To(Equal([]string{
				"K2s SYSTEM CHECK",
				"[PASS] Enough free disk space on the host: C:\\: 50GiB free",
				"[WARN] No APIPA address: APIPA address found on 'Ethernet'",
				"       Hint: renew the address",
				"[FAIL] Hyper-V service is running: service 'vmms' is not running",
				"       Hint: start the service",
				"[SKIP] Cluster certificates are valid: not applicable",
				"",
				"1 passed, 1 warning(s), 1 failed, 1 skipped",
			}))

			var failure *common.CmdFailure
			Expect(errors.As(err, &failure)).To(BeTrue())
			Expect(failure.Code).To(Equal(checkFailedCode))
			Expect(failure.Message).To(Equal("1 of 4 check(s) failed"))
			Expect(failure.SuppressCliOutput).To(BeFalse())
		})

		It("returns no error when no check failed", func() {
			printer := newUserFriendlyPrinter(&fakeTerminalPrinter{})

			err := printer.PrintReport(healthcheck.Report{Results: []healthcheck.Result{{Status: healthcheck.StatusWarn}}})

			Expect(err).ToNot(HaveOccurred())
		})

		It("returns provider errors from Run", func() {
			printer := newUserFriendlyPrinter(&fakeTerminalPrinter{})

			_, err := printer.Run(func() (healthcheck.Report, error) { return healthcheck.Report{}, errors.New("oops") })

			Expect(err).To(MatchError("oops"))
		})
	})
})
