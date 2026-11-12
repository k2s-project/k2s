// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package logging_test

import (
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/logging"
	"github.com/k2s-project/k2s/internal/test/reflection"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type flushMock struct {
	mock.Mock
}

func (m *flushMock) Flush(buffer []string) {
	m.Called(buffer)
}

func TestLogging(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Logging Tests", Label("logging"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(slog.NewTextHandler(GinkgoWriter, &slog.HandlerOptions{
		Level: slog.LevelDebug,
	})))
})

var _ = Describe("logging", func() {
	Describe("RootLogDir", Label("integration"), func() {
		It("returns root log dir from K2S_LOG_ROOT env var when set", func() {
			tempDir := GinkgoT().TempDir()
			GinkgoT().Setenv(logging.LogRootEnvVar, tempDir)
			logging.ResetRootLogDirCache()
			DeferCleanup(func() { logging.ResetRootLogDirCache() })

			dir := logging.RootLogDir()

			Expect(dir).To(Equal(filepath.Clean(tempDir)))
		})
	})

	Describe("GlobalLogFilePath", Label("integration"), func() {
		It("returns global log file path under the configured root", func() {
			tempDir := GinkgoT().TempDir()
			GinkgoT().Setenv(logging.LogRootEnvVar, tempDir)
			logging.ResetRootLogDirCache()
			DeferCleanup(func() { logging.ResetRootLogDirCache() })

			path := logging.GlobalLogFilePath()

			Expect(path).To(Equal(filepath.Join(filepath.Clean(tempDir), "k2s.log")))
		})
	})

	Describe("InitializeLogFile", Label("integration", "ci"), func() {
		When("dir not existing", func() {
			It("creates dir and log file", func() {
				tempDir := GinkgoT().TempDir()
				logFilePath := filepath.Join(tempDir, "test-dir", "test.log")

				GinkgoWriter.Println("Creating test log file <", logFilePath, ">..")

				result := logging.InitializeLogFile(logFilePath)
				DeferCleanup(func() {
					GinkgoWriter.Println("Closing test log file <", logFilePath, ">..")
					Expect(result.Close()).To(Succeed())
				})

				_, err := result.WriteString("test")
				Expect(err).ToNot(HaveOccurred())
			})
		})

		When("dir and log file existing", func() {
			It("opens existing log file", func() {
				tempDir := GinkgoT().TempDir()
				logFilePath := filepath.Join(tempDir, "test.log")
				logFile, err := os.OpenFile(
					logFilePath,
					os.O_APPEND|os.O_CREATE|os.O_WRONLY,
					os.ModePerm,
				)
				Expect(err).ToNot(HaveOccurred())

				_, err = logFile.WriteString("initial-content")
				Expect(err).ToNot(HaveOccurred())
				Expect(logFile.Close()).To(Succeed())

				GinkgoWriter.Println("Opening test log file <", logFilePath, ">..")

				result := logging.InitializeLogFile(logFilePath)
				DeferCleanup(func() {
					GinkgoWriter.Println("Closing test log file <", logFilePath, ">..")
					Expect(result.Close()).To(Succeed())
				})

				_, err = result.WriteString("test")
				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("SetVerbosity", Label("unit", "ci"), func() {
		When("verbosity parsing failed", func() {
			It("returns error", func() {
				const verbosity = "<invalid>"
				levelVar := new(slog.LevelVar)

				err := logging.SetVerbosity(verbosity, levelVar)

				Expect(err).To(MatchError(ContainSubstring("cannot convert")))
			})
		})

		When("verbosity passed as word", func() {
			It("returns correct level", func() {
				const verbosity = "debug"
				levelVar := new(slog.LevelVar)

				err := logging.SetVerbosity(verbosity, levelVar)

				Expect(err).ToNot(HaveOccurred())
				Expect(levelVar.Level()).To(Equal(slog.LevelDebug))
			})
		})

		When("verbosity passed as number", func() {
			It("returns correct level", func() {
				const verbosity = "4"
				levelVar := new(slog.LevelVar)

				err := logging.SetVerbosity(verbosity, levelVar)

				Expect(err).ToNot(HaveOccurred())
				Expect(levelVar.Level()).To(Equal(slog.LevelWarn))
			})
		})
	})

	Describe("LevelToLowerString", Label("unit", "ci"), func() {
		It("converts level to lower string", func() {
			actual := logging.LevelToLowerString(slog.LevelWarn)

			Expect(actual).To(Equal("warn"))
		})
	})

	Describe("ShortenSourceAttribute", Label("unit", "ci"), func() {
		When("attribute is not source attribute", func() {
			It("does nothing", func() {
				input := slog.Attr{Key: "some-key", Value: slog.StringValue("some-value")}

				actual := logging.ShortenSourceAttribute(nil, input)

				Expect(actual).To(Equal(input))
			})
		})

		When("attribute is source attribute", func() {
			It("shortens the properties", func() {
				source := &slog.Source{
					Function: "some-function",
					File:     "c:\\this\\is\\a\\full\\file.path",
				}
				input := slog.Attr{Key: slog.SourceKey, Value: slog.AnyValue(source)}

				actual := logging.ShortenSourceAttribute(nil, input)

				actualSource := actual.Value.Any().(*slog.Source)

				Expect(actualSource.Function).To(BeEmpty())
				Expect(actualSource.File).To(Equal("file.path"))
			})
		})
	})

	Describe("CleanLogDir", Label("integration", "ci"), func() {
		When("error occurs while reading dir", func() {
			It("returns error", func() {
				var maxAge time.Duration = 0

				err := logging.CleanLogDir("", maxAge)

				Expect(err).To(MatchError(ContainSubstring("failed to list files")))
			})
		})

		When("error occurs while deleting files", func() {
			var tempDir string
			var fileHandle *os.File

			BeforeEach(func() {
				tempDir = GinkgoT().TempDir()
				filePath := filepath.Join(tempDir, "test.log")
				Expect(os.WriteFile(filePath, []byte("test"), os.ModePerm)).To(Succeed())

				var err error
				fileHandle, err = os.OpenFile(filePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, fs.ModeExclusive)
				Expect(err).NotTo(HaveOccurred())

				GinkgoWriter.Println("Test log file <", filePath, "> opened")

				DeferCleanup(func() {
					if fileHandle == nil {
						GinkgoWriter.Println("File handle is nil")
						return
					}

					GinkgoWriter.Println("Closing test log file <", filePath, ">..")
					Expect(fileHandle.Close()).To(Succeed())
				})
			})

			It("returns error", FlakeAttempts(3), func() {
				Expect(fileHandle).NotTo(BeNil(), "handle must not be nil, otherwise this test is invalid")

				var maxAge time.Duration = -5 * time.Hour

				err := logging.CleanLogDir(tempDir, maxAge)

				Expect(err).To(MatchError(ContainSubstring("failed to delete outdated files")))
			})
		})

		When("file is younger than max age", func() {
			var tempDir string
			var filePath string

			BeforeEach(func() {
				tempDir = GinkgoT().TempDir()
				filePath = filepath.Join(tempDir, "test.log")
				Expect(os.WriteFile(filePath, []byte("test"), os.ModePerm)).To(Succeed())

				GinkgoWriter.Println("Test log file <", filePath, "> written")
			})

			It("it does not delete it", func() {
				maxAge := time.Second

				err := logging.CleanLogDir(tempDir, maxAge)

				Expect(err).NotTo(HaveOccurred())

				_, err = os.Stat(filePath)
				Expect(err).NotTo(HaveOccurred())
			})
		})

		When("file is older than max age", func() {
			var tempDir string
			var filePath string

			BeforeEach(func() {
				tempDir = GinkgoT().TempDir()
				filePath = filepath.Join(tempDir, "test.log")
				Expect(os.WriteFile(filePath, []byte("test"), os.ModePerm)).To(Succeed())

				GinkgoWriter.Println("Test log file <", filePath, "> written")

				waitTime := time.Millisecond

				GinkgoWriter.Printf("Waiting for %s to pass so that the test file becomes outdated..\n", waitTime)

				time.Sleep(waitTime)
			})

			It("it deletes it", func() {
				var maxAge time.Duration = 0

				err := logging.CleanLogDir(tempDir, maxAge)

				Expect(err).NotTo(HaveOccurred())

				_, err = os.Stat(filePath)
				Expect(err).To(MatchError(os.ErrNotExist))
			})
		})
	})

	Describe("SetupDefaultFileLogger", Label("integration", "ci"), func() {
		When("log file already exists", func() {
			When("error occurs while removing log file", func() {
				var tempDir string
				var fileName string

				BeforeEach(func() {
					tempDir = GinkgoT().TempDir()
					fileName = "test.log"
					filePath := filepath.Join(tempDir, fileName)
					Expect(os.WriteFile(filePath, []byte("test"), os.ModePerm)).To(Succeed())

					var err error
					fileHandle, err := os.OpenFile(filePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, fs.ModeExclusive)
					Expect(err).NotTo(HaveOccurred())

					GinkgoWriter.Println("Test log file <", filePath, "> opened")

					DeferCleanup(func() {
						if fileHandle == nil {
							return
						}

						GinkgoWriter.Println("Closing test log file <", filePath, ">..")
						Expect(fileHandle.Close()).To(Succeed())
					})
				})

				It("returns error", func() {
					expectedLevel := slog.LevelDebug

					file, err := logging.SetupDefaultFileLogger(tempDir, fileName, expectedLevel)

					Expect(file).To(BeNil())
					Expect(err).To(MatchError(ContainSubstring("cannot remove log file")))
				})
			})

			When("successful", Serial, func() {
				var tempDir string
				var fileName string
				var filePath string

				BeforeEach(func() {
					defaultLogger := slog.Default()

					tempDir = GinkgoT().TempDir()
					fileName = "test.log"
					filePath = filepath.Join(tempDir, fileName)
					Expect(os.WriteFile(filePath, []byte("test"), os.ModePerm)).To(Succeed())

					GinkgoWriter.Println("Test log file <", filePath, "> written")

					DeferCleanup(func() {
						GinkgoWriter.Println("resetting default logger")

						slog.SetDefault(defaultLogger)
					})
				})

				It("removes existing log file", func() {
					expectedLevel := slog.LevelDebug

					logFile, err := logging.SetupDefaultFileLogger(tempDir, fileName, expectedLevel)

					Expect(logFile.Close()).To(Succeed())
					Expect(err).ToNot(HaveOccurred())

					logFileContent, err := os.ReadFile(filePath)

					Expect(err).ToNot(HaveOccurred())
					Expect(logFileContent).To(HaveLen(0))
				})
			})
		})
		When("successful", Serial, func() {
			var tempDir string
			var fileName string
			var filePath string

			BeforeEach(func() {
				defaultLogger := slog.Default()

				tempDir = GinkgoT().TempDir()
				fileName = "test.log"
				filePath = filepath.Join(tempDir, fileName)
				Expect(os.WriteFile(filePath, []byte("test"), os.ModePerm)).To(Succeed())

				GinkgoWriter.Println("Test log file <", filePath, "> written")

				DeferCleanup(func() {
					GinkgoWriter.Println("resetting default logger")

					slog.SetDefault(defaultLogger)
				})
			})

			It("creates a working file logger", func() {
				expectedLevel := slog.LevelDebug
				expectedArgs := []any{"prop1", "val1", "prop2", "val2"}

				logFile, err := logging.SetupDefaultFileLogger(tempDir, fileName, expectedLevel, expectedArgs...)

				Expect(err).ToNot(HaveOccurred())

				slog.Debug("test-msg", "prop3", "val3")

				Expect(logFile.Close()).To(Succeed())

				logFileContent, err := os.ReadFile(filePath)

				Expect(err).ToNot(HaveOccurred())

				logs := strings.Split(string(logFileContent), " ")

				Expect(logs).To(HaveLen(6))

				_, err = time.Parse(time.RFC3339, logs[0][len("time="):])
				Expect(err).ToNot(HaveOccurred())

				Expect(logs).To(ContainElement(ContainSubstring("level=DEBUG")))
				Expect(logs).To(ContainElement(ContainSubstring("msg=test-msg")))
				Expect(logs).To(ContainElement(ContainSubstring("prop1=val1")))
				Expect(logs).To(ContainElement(ContainSubstring("prop2=val2")))
				Expect(logs).To(ContainElement(ContainSubstring("prop3=val3")))
			})
		})
	})

	Describe("LogBuffer", Label("unit", "ci"), func() {
		Describe("NewLogBuffer", func() {
			When("buffer limit is 0", func() {
				It("limit is reset to default", func() {
					const arbitraryOffset = 10
					called := false

					flushMock := &flushMock{}
					flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything).Once().Run(func(args mock.Arguments) {
						called = true

						buffer := args.Get(0).([]string)
						Expect(buffer).To(HaveLen(int(logging.DefaultBufferLimit)))
					})

					config := logging.BufferConfig{
						Limit:     0,
						FlushFunc: flushMock.Flush,
					}

					buffer := logging.NewLogBuffer(config)

					for i := 0; i <= int(logging.DefaultBufferLimit)+arbitraryOffset; i++ {
						buffer.Log("test")
					}

					Expect(called).To(BeTrue())
					flushMock.AssertExpectations(GinkgoT())
				})
			})

			When("flush function is nil", func() {
				It("function is set to stub doing nothing", func() {
					config := logging.BufferConfig{
						FlushFunc: nil,
						Limit:     5,
					}
					runs := config.Limit * 2 // ensure flush is called at least once

					buffer := logging.NewLogBuffer(config)

					for i := 0; i <= int(runs); i++ {
						buffer.Log("test")
					}
				})
			})

			When("limit and flush function set", func() {
				It("flush function is invoked when the limit is reached", func() {
					const limit = 5
					const invocations = 15
					expectedFlushTimes := invocations / limit

					flushMock := &flushMock{}
					flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything).Times(expectedFlushTimes).Run(func(args mock.Arguments) {
						buffer := args.Get(0).([]string)
						Expect(buffer).To(HaveLen(limit))
					})

					config := logging.BufferConfig{
						Limit:     limit,
						FlushFunc: flushMock.Flush,
					}

					buffer := logging.NewLogBuffer(config)

					for i := 0; i <= invocations; i++ {
						buffer.Log("test")
					}

					flushMock.AssertExpectations(GinkgoT())
				})
			})
		})

		Describe("Log", func() {
			When("buffer limit is not reached", func() {
				It("log line is written to buffer only", func() {
					flushMock := &flushMock{}
					flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					config := logging.BufferConfig{
						Limit:     4,
						FlushFunc: flushMock.Flush,
					}

					logger := logging.NewLogBuffer(config)

					logger.Log("a")
					logger.Log("b")
					logger.Log("c")

					flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					logger.Flush()

					flushMock.AssertCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)
				})
			})

			When("buffer limit is reached", func() {
				It("log line is written to buffer and buffer is flushed", func() {
					flushMock := &flushMock{}
					flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					config := logging.BufferConfig{
						Limit:     3,
						FlushFunc: flushMock.Flush,
					}

					logger := logging.NewLogBuffer(config)

					logger.Log("a")
					logger.Log("b")

					flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					logger.Log("c")

					flushMock.AssertCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					flushMock.Calls = []mock.Call{}

					logger.Log("d")

					flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)
				})
			})
		})

		Describe("Flush", func() {
			It("flushes the content in correct format and emties the buffer", func() {
				flushMock := &flushMock{}
				flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything)

				config := logging.BufferConfig{
					Limit:     4,
					FlushFunc: flushMock.Flush,
				}

				logger := logging.NewLogBuffer(config)

				logger.Log("a")
				logger.Log("b")
				logger.Log("c")

				flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)

				logger.Flush()

				flushMock.AssertCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.MatchedBy(func(buffer []string) bool {
					return Expect(buffer).To(ContainElements([]string{"a", "b", "c"}))
				}))

				flushMock.Calls = []mock.Call{}

				logger.Flush()

				flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)
			})
		})
	})
})
