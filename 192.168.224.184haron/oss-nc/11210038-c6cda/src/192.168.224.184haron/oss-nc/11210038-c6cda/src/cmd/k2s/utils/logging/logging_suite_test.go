// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package logging_test

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	"github.com/pterm/pterm"
	"github.com/k2s-project/k2s/cmd/k2s/utils/logging"
	"github.com/k2s-project/k2s/internal/test/reflection"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type handlerMock struct {
	mock.Mock
}

func (m *handlerMock) Enabled(ctx context.Context, level slog.Level) bool {
	args := m.Called(ctx, level)

	return args.Bool(0)
}

func (m *handlerMock) Handle(ctx context.Context, record slog.Record) error {
	args := m.Called(ctx, record)

	return args.Error(0)
}

func (m *handlerMock) WithAttrs(attrs []slog.Attr) slog.Handler {
	args := m.Called(attrs)

	return args.Get(0).(slog.Handler)
}

func (m *handlerMock) WithGroup(name string) slog.Handler {
	args := m.Called(name)

	return args.Get(0).(slog.Handler)
}

func (m *handlerMock) Flush() {
	m.Called()
}

func (m *handlerMock) Close() {
	m.Called()
}

func TestLogging(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "logging package", Label("ci", "cmd", "k2s", "utils", "logging"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("logging pkg", func() {
	Describe("logging", Label("unit"), func() {
		Describe("NewSlogger", func() {
			It("returns default slog logger", func() {
				result := logging.NewSlogger()

				Expect(result.Logger).To(Equal(slog.Default()))
			})
		})

		Describe("SetHandlers", func() {
			It("calls flush and close on all existing handlers first", func() {
				oldHandler1 := &handlerMock{}
				oldHandler1.On(reflection.GetFunctionName(oldHandler1.Flush)).Once()
				oldHandler1.On(reflection.GetFunctionName(oldHandler1.Close)).Once()

				oldHandler2 := &handlerMock{}
				oldHandler2.On(reflection.GetFunctionName(oldHandler2.Flush)).Once()
				oldHandler2.On(reflection.GetFunctionName(oldHandler2.Close)).Once()

				oldHandlerFunc1 := func(levelVar *slog.LevelVar) logging.SlogHandler {
					return oldHandler1
				}
				oldHandlerFunc2 := func(levelVar *slog.LevelVar) logging.SlogHandler {
					return oldHandler2
				}
				newHandlerFunc := func(levelVar *slog.LevelVar) logging.SlogHandler {
					return &handlerMock{}
				}

				sut := logging.NewSlogger()

				sut.SetHandlers(oldHandlerFunc1, oldHandlerFunc2)
				sut.SetHandlers(newHandlerFunc)

				oldHandler1.AssertExpectations(GinkgoT())
				oldHandler2.AssertExpectations(GinkgoT())
			})

			It("creates new logger with multi-handler", func() {
				handler1 := &handlerMock{}
				handler1.On(reflection.GetFunctionName(handler1.Enabled), mock.Anything, mock.Anything).Return(false).Once()

				handler2 := &handlerMock{}
				handler2.On(reflection.GetFunctionName(handler2.Enabled), mock.Anything, mock.Anything).Return(false).Once()

				handlerFunc1 := func(levelVar *slog.LevelVar) logging.SlogHandler {
					return handler1
				}
				handlerFunc2 := func(levelVar *slog.LevelVar) logging.SlogHandler {
					return handler2
				}

				sut := logging.NewSlogger()

				sut.SetHandlers(handlerFunc1, handlerFunc2)

				sut.Logger.Info("test")

				handler1.AssertExpectations(GinkgoT())
				handler2.AssertExpectations(GinkgoT())
			})

			It("returns itself", func() {
				sut := logging.NewSlogger()

				result := sut.SetHandlers()

				Expect(result).To(Equal(sut))
			})
		})

		Describe("SetGlobally", func() {
			BeforeEach(func() {
				originalLogger := slog.Default()

				DeferCleanup(func() {
					slog.SetDefault(originalLogger)
				})
			})

			It("sets the logger as global default", func() {
				handlerFunc := func(levelVar *slog.LevelVar) logging.SlogHandler {
					return &handlerMock{}
				}

				sut := logging.NewSlogger().SetHandlers(handlerFunc)

				result := sut.SetGlobally()

				Expect(result).To(Equal(sut))
				Expect(slog.Default()).To(Equal(sut.Logger))
			})
		})

		Describe("SetVerbosity", func() {
			It("sets verbosity/log level on logger", func(ctx context.Context) {
				const verbosity = "debug"
				var levelVar *slog.LevelVar

				handlerFunc := func(lv *slog.LevelVar) logging.SlogHandler {
					levelVar = lv
					return &handlerMock{}
				}

				sut := logging.NewSlogger().SetHandlers(handlerFunc)

				err := sut.SetVerbosity(verbosity)

				Expect(err).ToNot(HaveOccurred())
				Expect(levelVar.Level()).To(Equal(slog.LevelDebug))
			})
		})
	})

	Describe("cli", Label("unit"), func() {
		Describe("MapLogLevel", func() {
			DescribeTable("maps log level correctly", func(input slog.Level, expected pterm.LogLevel) {
				actual := logging.MapLogLevel(input)

				Expect(actual).To(Equal(expected))
			},
				Entry("greater than slog's error -> fatal", slog.LevelError+2, pterm.LogLevelFatal),
				Entry("equal to slog's error -> error", slog.LevelError, pterm.LogLevelError),
				Entry("between slog's error and warn -> warn", slog.LevelWarn+2, pterm.LogLevelWarn),
				Entry("equal to slog's warn -> warn", slog.LevelWarn, pterm.LogLevelWarn),
				Entry("between slog's warn and info -> info", slog.LevelInfo+2, pterm.LogLevelInfo),
				Entry("equal to slog's info -> info", slog.LevelInfo, pterm.LogLevelInfo),
				Entry("between slog's info and debug -> debug", slog.LevelDebug+2, pterm.LogLevelDebug),
				Entry("equal to slog's debug -> debug", slog.LevelDebug, pterm.LogLevelDebug),
				Entry("less than slog's debug -> trace", slog.LevelDebug-2, pterm.LogLevelTrace),
			)
		})
	})

	Describe("file", Label("integration"), func() {
		It("logs to file", func() {
			logFilePath := filepath.Join(GinkgoT().TempDir(), "log.file")
			logger := logging.NewSlogger().SetHandlers(logging.NewFileHandler(logFilePath))

			logger.Logger.Info("test-1")
			logger.Logger.Info("test-2")
			logger.Logger.Info("test-3")

			logger.Flush()
			logger.Close()

			data, err := os.ReadFile(logFilePath)
			Expect(err).ToNot(HaveOccurred())

			Expect(string(data)).To(SatisfyAll(
				ContainSubstring("test-1"),
				ContainSubstring("test-2"),
				ContainSubstring("test-3"),
			))
		})

		It("flushing and closing already closed file does nothing", func() {
			logFilePath := filepath.Join(GinkgoT().TempDir(), "log.file")
			logger := logging.NewSlogger().SetHandlers(logging.NewFileHandler(logFilePath))
			logger.Close()

			logger.Flush()
			logger.Close()
		})
	})
})
