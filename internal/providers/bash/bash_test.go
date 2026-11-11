// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package bash

import (
	"bytes"
	"context"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type writer = func(string, ...any)

func TestBashPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "bash pkg Tests", Label("ci", "internal", "bash"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("bash pkg", Label("unit"), func() {
	const windowsError = "not available on Windows hosts"

	Describe("platformGuard", func() {
		It("rejects Windows only", func() {
			err := platformGuard()

			if runtime.GOOS == "windows" {
				Expect(err).To(MatchError(ContainSubstring(windowsError)))
			} else {
				Expect(err).ToNot(HaveOccurred())
			}
		})
	})

	Describe("Exec", func() {
		When("running on Windows", func() {
			BeforeEach(func() {
				if runtime.GOOS != "windows" {
					Skip("Windows-only execution guard")
				}
			})

			It("rejects execution before running the command", func() {
				for _, sut := range []*scriptBuilder{
					NewScript("missing.sh"),
					NewScript("missing.sh").WithContext(context.Background()),
					NewScript("missing.sh").WithStdOutWriter(nil).WithStdErrWriter(nil),
				} {
					Expect(sut.Exec()).To(MatchError(ContainSubstring(windowsError)))
				}
			})
		})

		When("running on Linux", func() {
			var logs *bytes.Buffer
			var scriptPath string

			BeforeEach(func() {
				if runtime.GOOS != "linux" {
					Skip("Linux script execution")
				}
				if _, err := exec.LookPath("bash"); err != nil {
					Skip("bash is not available")
				}

				logs = &bytes.Buffer{}
				previous := slog.Default()
				slog.SetDefault(slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
				DeferCleanup(slog.SetDefault, previous)

				scriptPath = filepath.Join(GinkgoT().TempDir(), "script.sh")
				content := `[[ ${K2S_LOG_TO_CLI:-false} == true ]] || exit 4
[[ "$#" == 2 && "$2" == 'literal argument; $HOME' ]] || exit 5
printf '%s\n' 'script stdout'
printf '%s\n' 'script stderr' >&2
exit "$1"
`
				Expect(os.WriteFile(scriptPath, []byte(content), 0600)).To(Succeed())
			})

			DescribeTable("routes script output to the configured writers",
				func(withWriters bool, stdOut, stdErr writer, stdOutLevel, stdErrLevel string) {
					sut := NewScript(scriptPath).WithArgs("0", "literal argument; $HOME")
					if withWriters {
						sut.WithContext(context.Background()).WithStdOutWriter(stdOut).WithStdErrWriter(stdErr)
					}

					Expect(sut.Exec()).To(Succeed())

					expectLog := func(level, msg string) {
						if level == "" {
							Expect(logs.String()).ToNot(ContainSubstring(msg))
						} else {
							Expect(logs.String()).To(ContainSubstring("level=" + level + " " + msg))
						}
					}
					expectLog(stdOutLevel, `msg="script stdout"`)
					expectLog(stdErrLevel, `msg="script stderr"`)
				},
				Entry("defaults", false, nil, nil, "INFO", "ERROR"),
				Entry("custom writers", true, slog.Debug, slog.Warn, "DEBUG", "WARN"),
				Entry("nil stdout discards stdout", true, nil, slog.Warn, "", "WARN"),
				Entry("nil stderr discards stderr", true, slog.Debug, nil, "DEBUG", ""),
			)

			When("script exits with non-zero status", func() {
				It("returns the exit error", func() {
					err := NewScript(scriptPath).WithArgs("3", "literal argument; $HOME").Exec()

					Expect(err).To(MatchError(ContainSubstring("exit status 3")))
				})
			})
		})
	})
})
