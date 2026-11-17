// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package bash

import (
	"bytes"
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

type recordingWriter struct {
	stdOut []string
	stdErr []string
}

func (w *recordingWriter) WriteStdOut(message string) { w.stdOut = append(w.stdOut, message) }
func (w *recordingWriter) WriteStdErr(message string) { w.stdErr = append(w.stdErr, message) }
func (w *recordingWriter) Flush()                     {}

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
					NewScript("missing.sh").WithShowLogs(true).WithStdWriter(nil),
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
				content := `printf '%s\n' "show=${K2S_SHOW_LOGS:-unset}"
[[ "$#" == 2 && "$2" == 'literal argument; $HOME' ]] || exit 5
printf '%s\n' 'script stdout'
printf '%s\n' 'script stderr' >&2
exit "$1"
`
				Expect(os.WriteFile(scriptPath, []byte(content), 0600)).To(Succeed())
			})

			It("forwards stdout and stderr to the writer without logging the content", func() {
				writer := &recordingWriter{}

				err := NewScript(scriptPath).WithArgs("0", "literal argument; $HOME").WithStdWriter(writer).Exec()

				Expect(err).ToNot(HaveOccurred())
				Expect(writer.stdOut).To(Equal([]string{"show=unset", "script stdout"}))
				Expect(writer.stdErr).To(Equal([]string{"script stderr"}))
				Expect(logs.String()).ToNot(ContainSubstring("script stdout"))
				Expect(logs.String()).ToNot(ContainSubstring("script stderr"))
			})

			It("tells the script to show its logs", func() {
				writer := &recordingWriter{}

				err := NewScript(scriptPath).WithArgs("0", "literal argument; $HOME").WithShowLogs(true).WithStdWriter(writer).Exec()

				Expect(err).ToNot(HaveOccurred())
				Expect(writer.stdOut).To(ContainElement("show=true"))
			})

			It("discards the output without a writer", func() {
				err := NewScript(scriptPath).WithArgs("0", "literal argument; $HOME").WithStdWriter(nil).Exec()

				Expect(err).ToNot(HaveOccurred())
				Expect(logs.String()).ToNot(ContainSubstring("script stdout"))
			})

			When("script exits with non-zero status", func() {
				It("returns the exit error and still forwards the output", func() {
					writer := &recordingWriter{}

					err := NewScript(scriptPath).WithArgs("3", "literal argument; $HOME").WithStdWriter(writer).Exec()

					Expect(err).To(MatchError(ContainSubstring("exit status 3")))
					Expect(writer.stdErr).To(Equal([]string{"script stderr"}))
				})
			})
		})
	})
})
