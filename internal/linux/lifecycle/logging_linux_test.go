// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package lifecycle

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type scriptResult struct {
	stdOut  string
	stdErr  string
	logFile string
}

var _ = Describe("logging.sh", Label("unit"), func() {
	const stdOutAndFileScript = `printf '%s\n' 'piped line' | k2s_log_output`

	var logFile string

	BeforeEach(func() {
		logFile = filepath.Join(GinkgoT().TempDir(), "k2s.log")
	})

	run := func(showLogs bool, body string) scriptResult {
		module, err := filepath.Abs(linuxModulePath(filepath.Join("common", "logging.sh")))
		Expect(err).ToNot(HaveOccurred())

		cmd := exec.Command("bash", "-c", "set -euo pipefail\nsource \"$1\"\n"+body, "bash", module)
		cmd.Env = append(os.Environ(), "K2S_LOG_FILE="+logFile)
		if showLogs {
			cmd.Env = append(cmd.Env, "K2S_SHOW_LOGS=true")
		} else {
			cmd.Env = append(cmd.Env, "K2S_SHOW_LOGS=")
		}
		var stdOut, stdErr bytes.Buffer
		cmd.Stdout = &stdOut
		cmd.Stderr = &stdErr
		Expect(cmd.Run()).To(Succeed())

		data, err := os.ReadFile(logFile)
		Expect(err).ToNot(HaveOccurred())

		return scriptResult{stdOut: stdOut.String(), stdErr: stdErr.String(), logFile: string(data)}
	}

	Describe("k2s_log", func() {
		When("logs are not shown", func() {
			It("writes info messages to the log file only", func() {
				result := run(false, "k2s_initialize_logging\nk2s_log INFO 'info message'")

				Expect(result.stdOut).To(BeEmpty())
				Expect(result.stdErr).To(BeEmpty())
				Expect(result.logFile).To(MatchRegexp(` \[INFO\] info message\n`))
			})

			It("writes warnings and errors to the log file and to stderr", func() {
				result := run(false, "k2s_initialize_logging\nk2s_log WARN 'warn message'\nk2s_log ERROR 'error message'")

				Expect(result.stdOut).To(BeEmpty())
				Expect(result.stdErr).To(Equal("warn message\nerror message\n"))
				Expect(result.logFile).To(ContainSubstring(" [WARN] warn message\n"))
				Expect(result.logFile).To(ContainSubstring(" [ERROR] error message\n"))
			})
		})

		When("logs are shown", func() {
			It("writes info messages to the log file and to stdout", func() {
				result := run(true, "k2s_initialize_logging\nk2s_log INFO 'info message'")

				Expect(result.stdOut).To(Equal("info message\n"))
				Expect(result.stdErr).To(BeEmpty())
				Expect(result.logFile).To(ContainSubstring(" [INFO] info message\n"))
			})
		})
	})

	Describe("k2s_log_prereq_failure", func() {
		It("writes the pre-requisite marker to the log file and to stderr", func() {
			result := run(false, "k2s_initialize_logging\nk2s_log_prereq_failure 'swap is enabled'")

			Expect(result.stdOut).To(BeEmpty())
			Expect(result.stdErr).To(Equal("[PREREQ-FAILED] swap is enabled\n"))
			Expect(result.logFile).To(ContainSubstring(" [ERROR] [PREREQ-FAILED] swap is enabled\n"))
		})
	})

	Describe("k2s_log_output", func() {
		When("logs are not shown", func() {
			It("appends the input to the log file only", func() {
				result := run(false, "k2s_initialize_logging\n"+stdOutAndFileScript)

				Expect(result.stdOut).To(BeEmpty())
				Expect(result.logFile).To(Equal("piped line\n"))
			})
		})

		When("logs are shown", func() {
			It("appends the input to the log file and passes it on to stdout", func() {
				result := run(true, "k2s_initialize_logging\n"+stdOutAndFileScript)

				Expect(result.stdOut).To(Equal("piped line\n"))
				Expect(result.logFile).To(Equal("piped line\n"))
			})
		})
	})

	Describe("k2s_initialize_logging --capture", func() {
		const captureScript = `k2s_initialize_logging --capture
printf '%s\n' 'raw stdout'
printf '%s\n' 'raw stderr' >&2
k2s_log INFO 'info message'
k2s_log ERROR 'error message'
printf '%s\n' 'piped line' | k2s_log_output`

		When("logs are not shown", func() {
			It("writes everything to the log file and only errors to stderr", func() {
				result := run(false, captureScript)

				Expect(result.stdOut).To(BeEmpty())
				Expect(result.stdErr).To(ContainSubstring("raw stderr\n"))
				Expect(result.stdErr).To(ContainSubstring("error message\n"))
				Expect(result.stdErr).ToNot(ContainSubstring("info message"))
				for _, line := range []string{"raw stdout", "raw stderr", " [INFO] info message", " [ERROR] error message", "piped line"} {
					Expect(result.logFile).To(ContainSubstring(line))
				}
			})
		})

		When("logs are shown", func() {
			It("writes everything to the log file and the regular output to stdout as well", func() {
				result := run(true, captureScript)

				Expect(result.stdOut).To(ContainSubstring("raw stdout\n"))
				Expect(result.stdOut).To(ContainSubstring("info message\n"))
				Expect(result.stdOut).To(ContainSubstring("piped line\n"))
				Expect(result.stdErr).To(ContainSubstring("error message\n"))
				for _, line := range []string{"raw stdout", "raw stderr", " [INFO] info message", " [ERROR] error message", "piped line"} {
					Expect(result.logFile).To(ContainSubstring(line))
				}
			})
		})
	})
})
