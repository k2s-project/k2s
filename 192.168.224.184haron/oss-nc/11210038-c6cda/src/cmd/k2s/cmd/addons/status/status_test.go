// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package status

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/contracts/config"
	r "github.com/k2s-project/k2s/internal/test/reflection"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

type nullableOkay struct {
	value bool
}

type nullableMessage struct {
	value string
}

func (m *mockObject) PrintStatus(addonName string, addonDirectory string) error {
	args := m.Called(addonName, addonDirectory)

	return args.Error(0)
}

func (m *mockObject) loadAddonStatus(addonName string, implementation string) (*LoadedAddonStatus, error) {
	args := m.Called(addonName, implementation)

	return args.Get(0).(*LoadedAddonStatus), args.Error(1)
}

func (m *mockObject) marshalIndent(data any) ([]byte, error) {
	args := m.Called(data)

	return args.Get(0).([]byte), args.Error(1)
}

func (mo *mockObject) Println(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintSuccess(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintWarning(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintHeader(m ...any) {
	mo.Called(m...)
}

func (m *mockObject) PrintCyanFg(text string) string {
	args := m.Called(text)

	return args.String(0)
}

func (mo *mockObject) StartSpinner(m ...any) (any, error) {
	args := mo.Called(m...)

	return args.Get(0), args.Error(1)
}

func (m *mockObject) Stop() error {
	args := m.Called()

	return args.Error(0)
}

func (m *mockObject) PrintProp(prop AddonStatusProp) {
	m.Called(prop)
}

func TestStatusPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addon status pkg Unit Tests", Label("unit", "ci", "status"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("status pkg", func() {
	Describe("determinePrinter", func() {
		When("json option is passed", func() {
			It("returns json printer", func() {
				result := determinePrinter(jsonOption)

				Expect(result).To(BeAssignableToTypeOf(&JsonPrinter{}))
			})
		})

		When("no option is passed", func() {
			It("returns user-friendly printer", func() {
				result := determinePrinter("")

				Expect(result).To(BeAssignableToTypeOf(&UserFriendlyPrinter{}))
			})
		})

		When("invalid option is passed", func() {
			It("returns user-friendly printer", func() {
				result := determinePrinter("invalid")

				Expect(result).To(BeAssignableToTypeOf(&UserFriendlyPrinter{}))
			})
		})
	})

	Describe("JsonPrinter", func() {
		Describe("PrintStatus", func() {
			When("status load error occurred", func() {
				It("returns error without printing", func() {
					addonName := "test-addon"
					implementation := "test-implementation"
					expectedError := errors.New("oops")

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(&LoadedAddonStatus{}, expectedError)

					sut := NewJsonPrinter(nil, nil)

					err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("marshalling error occurred", func() {
				It("returns error without printing", func() {
					addonName := "test-addon"
					implementation := "test-implementation"
					expectedError := errors.New("oops")
					loadStatus := &LoadedAddonStatus{Props: []AddonStatusProp{{Name: "test-key", Value: "test-val"}}}

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(loadStatus, nil)

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && status.Props[0] == loadStatus.Props[0]
					})).Return(make([]byte, 0), expectedError)

					sut := NewJsonPrinter(nil, marshalMock.marshalIndent)

					err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("successful", func() {
				It("prints the status without error", func() {
					addonName := "test-addon"
					implementation := "test-implementation"
					loadStatus := &LoadedAddonStatus{Props: []AddonStatusProp{{Name: "test-key", Value: "test-val"}}}
					statusBytes := []byte("status")

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(loadStatus, nil)

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && status.Props[0] == loadStatus.Props[0]
					})).Return(statusBytes, nil)

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), "status").Once()

					sut := NewJsonPrinter(printerMock, marshalMock.marshalIndent)

					err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

					Expect(err).ToNot(HaveOccurred())
					printerMock.AssertExpectations(GinkgoT())
				})
			})
		})

		Describe("PrintSystemNotInstalledError", func() {
			When("marshalling error occurred", func() {
				It("returns error without printing", func() {
					addonName := "test-addon"
					expectedError := errors.New("oops")

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName
					})).Return(make([]byte, 0), expectedError)

					sut := NewJsonPrinter(nil, marshalMock.marshalIndent)

					err := sut.PrintSystemError(addonName, config.ErrSystemNotInstalled, common.CreateSystemNotInstalledCmdFailure)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("successful", func() {
				It("prints JSON with failure and returns silent cmd failure", func() {
					addonName := "test-addon"
					statusBytes := []byte("status-JSON")

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && *status.Error == config.ErrSystemNotInstalled.Error()
					})).Return(statusBytes, nil)

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), "status-JSON").Once()

					sut := NewJsonPrinter(printerMock, marshalMock.marshalIndent)

					err := sut.PrintSystemError(addonName, config.ErrSystemNotInstalled, common.CreateSystemNotInstalledCmdFailure)

					var cmdFailure *common.CmdFailure
					Expect(errors.As(err, &cmdFailure)).To(BeTrue())
					Expect(cmdFailure.Code).To(Equal(config.ErrSystemNotInstalled.Error()))
					Expect(cmdFailure.Message).To(Equal(common.ErrSystemNotInstalledMsg))
					Expect(cmdFailure.Severity).To(Equal(common.SeverityWarning))
					Expect(cmdFailure.SuppressCliOutput).To(BeTrue())

					printerMock.AssertExpectations(GinkgoT())
				})
			})
		})

		Describe("PrintSystemInCorruptedStateError", func() {
			When("marshalling error occurred", func() {
				It("returns error without printing", func() {
					addonName := "test-addon"
					expectedError := errors.New("oops")

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName
					})).Return(make([]byte, 0), expectedError)

					sut := NewJsonPrinter(nil, marshalMock.marshalIndent)

					err := sut.PrintSystemError(addonName, config.ErrSystemInCorruptedState, common.CreateSystemInCorruptedStateCmdFailure)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("successful", func() {
				It("prints JSON with failure and returns silent cmd failure", func() {
					addonName := "test-addon"
					statusBytes := []byte("status-JSON")

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && *status.Error == config.ErrSystemInCorruptedState.Error()
					})).Return(statusBytes, nil)

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), "status-JSON").Once()

					sut := NewJsonPrinter(printerMock, marshalMock.marshalIndent)

					err := sut.PrintSystemError(addonName, config.ErrSystemInCorruptedState, common.CreateSystemInCorruptedStateCmdFailure)

					var cmdFailure *common.CmdFailure
					Expect(errors.As(err, &cmdFailure)).To(BeTrue())
					Expect(cmdFailure.Code).To(Equal(config.ErrSystemInCorruptedState.Error()))
					Expect(cmdFailure.Message).To(Equal(common.ErrSystemInCorruptedStateMsg))
					Expect(cmdFailure.Severity).To(Equal(common.SeverityError))
					Expect(cmdFailure.SuppressCliOutput).To(BeTrue())

					printerMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})

	Describe("UserFriendlyPrinter", func() {
		Describe("PrintStatus", func() {
			When("spinner start error occurred", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(nil, expectedError)

					sut := NewUserFriendlyPrinter(printerMock, nil)

					err := sut.PrintStatus("", "", nil)

					Expect(err).To(MatchError(expectedError))
					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("spinner type conversion failed", func() {
				It("returns error", func() {
					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return("not-a-spinner", nil)

					sut := NewUserFriendlyPrinter(printerMock, nil)

					err := sut.PrintStatus("", "", nil)

					Expect(err).To(MatchError(ContainSubstring("could not start")))
					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("unknown status load error occurred", func() {
				It("returns error", func() {
					addonName := "test-addon"
					implementation := "test-implementation"
					expectedError := errors.New("oops")

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(&LoadedAddonStatus{}, expectedError)

					sut := NewUserFriendlyPrinter(printerMock)

					err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

					Expect(err).To(MatchError(expectedError))

					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("status does not contain enabled/disabled information", func() {
				It("returns error", func() {
					addonName := "test-addon"
					implementation := "test-implementation"
					loadedStatus := &LoadedAddonStatus{}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(loadedStatus, nil)

					sut := NewUserFriendlyPrinter(printerMock)

					err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

					Expect(err).To(MatchError(ContainSubstring("info missing")))

					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("addon is disabled", func() {
				When("addon has different implementations", func() {
					It("prints the disabled-status", func() {
						addonName := "test-addon"
						implementation := "test-implementation"
						state := "disabled"
						loadedStatus := &LoadedAddonStatus{Enabled: new(false)}

						spinnerMock := &mockObject{}
						spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

						printerMock := &mockObject{}
						printerMock.On(r.GetFunctionName(printerMock.PrintHeader), "ADDON STATUS").Once()
						printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
						printerMock.On(r.GetFunctionName(printerMock.Println), "Implementation", implementation, "of Addon", addonName, "is", state).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), implementation).Return(implementation).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), addonName).Return(addonName).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), state).Return(state).Once()

						loaderMock := &mockObject{}
						loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(loadedStatus, nil)

						sut := NewUserFriendlyPrinter(printerMock)

						err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

						Expect(err).ToNot(HaveOccurred())
						printerMock.AssertExpectations(GinkgoT())
						spinnerMock.AssertExpectations(GinkgoT())
					})
				})

				When("addon has only one implementations", func() {
					It("prints the disabled-status", func() {
						addonName := "test-addon"
						implementation := ""
						state := "disabled"
						loadedStatus := &LoadedAddonStatus{Enabled: new(false)}

						spinnerMock := &mockObject{}
						spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

						printerMock := &mockObject{}
						printerMock.On(r.GetFunctionName(printerMock.PrintHeader), "ADDON STATUS").Once()
						printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
						printerMock.On(r.GetFunctionName(printerMock.Println), "Addon", addonName, "is", state).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), addonName).Return(addonName).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), state).Return(state).Once()

						loaderMock := &mockObject{}
						loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(loadedStatus, nil)

						sut := NewUserFriendlyPrinter(printerMock)

						err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

						Expect(err).ToNot(HaveOccurred())
						printerMock.AssertExpectations(GinkgoT())
						spinnerMock.AssertExpectations(GinkgoT())
					})
				})
			})

			When("addon is enabled", func() {
				When("addon has different implementations", func() {
					It("prints the enabled-status", func() {
						addonName := "test-addon"
						implementation := "test-implementation"
						state := "enabled"
						loadedStatus := &LoadedAddonStatus{Enabled: new(true)}

						spinnerMock := &mockObject{}
						spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

						printerMock := &mockObject{}
						printerMock.On(r.GetFunctionName(printerMock.PrintHeader), "ADDON STATUS").Once()
						printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
						printerMock.On(r.GetFunctionName(printerMock.Println), "Implementation", implementation, "of Addon", addonName, "is", state).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), implementation).Return(implementation).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), addonName).Return(addonName).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), state).Return(state).Once()

						loaderMock := &mockObject{}
						loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(loadedStatus, nil)

						sut := NewUserFriendlyPrinter(printerMock)

						err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

						Expect(err).ToNot(HaveOccurred())
						printerMock.AssertExpectations(GinkgoT())
						spinnerMock.AssertExpectations(GinkgoT())
					})
				})

				When("addon has only one implementations", func() {
					It("prints the enabled-status", func() {
						addonName := "test-addon"
						implementation := ""
						state := "enabled"
						loadedStatus := &LoadedAddonStatus{Enabled: new(true)}

						spinnerMock := &mockObject{}
						spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

						printerMock := &mockObject{}
						printerMock.On(r.GetFunctionName(printerMock.PrintHeader), "ADDON STATUS").Once()
						printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
						printerMock.On(r.GetFunctionName(printerMock.Println), "Addon", addonName, "is", state).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), addonName).Return(addonName).Once()
						printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), state).Return(state).Once()

						loaderMock := &mockObject{}
						loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(loadedStatus, nil)

						sut := NewUserFriendlyPrinter(printerMock)

						err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

						Expect(err).ToNot(HaveOccurred())
						printerMock.AssertExpectations(GinkgoT())
						spinnerMock.AssertExpectations(GinkgoT())
					})
				})

				It("prints the addon-specific props", func() {
					addonName := "test-addon"
					implementation := "test-implementation"
					loadedStatus := &LoadedAddonStatus{
						Enabled: new(true),
						Props: []AddonStatusProp{
							{Name: "p1"},
							{Name: "p2"},
						},
					}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.Println), mock.Anything, mock.Anything, mock.Anything, mock.Anything, mock.Anything, mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("colored-text")

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName, implementation).Return(loadedStatus, nil)

					propPrintMock := &mockObject{}
					propPrintMock.On(r.GetFunctionName(propPrintMock.PrintProp), loadedStatus.Props[0]).Once()
					propPrintMock.On(r.GetFunctionName(propPrintMock.PrintProp), loadedStatus.Props[1]).Once()

					sut := NewUserFriendlyPrinter(printerMock, propPrintMock)

					err := sut.PrintStatus(addonName, implementation, loaderMock.loadAddonStatus)

					Expect(err).ToNot(HaveOccurred())
					propPrintMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})
		})

		Describe("PrintSystemNotInstalledError", func() {
			It("returns system-not-installed command failure", func() {
				sut := NewUserFriendlyPrinter(nil)

				err := sut.PrintSystemError("", config.ErrSystemNotInstalled, common.CreateSystemNotInstalledCmdFailure)

				var cmdFailure *common.CmdFailure
				Expect(errors.As(err, &cmdFailure)).To(BeTrue())
				Expect(cmdFailure.Code).To(Equal(config.ErrSystemNotInstalled.Error()))
				Expect(cmdFailure.Message).To(Equal(common.ErrSystemNotInstalledMsg))
				Expect(cmdFailure.Severity).To(Equal(common.SeverityWarning))
				Expect(cmdFailure.SuppressCliOutput).To(BeFalse())
			})
		})

		Describe("PrintSystemInCorruptedStateError", func() {
			It("returns system-in-corrupted-state command failure", func() {
				sut := NewUserFriendlyPrinter(nil)

				err := sut.PrintSystemError("", config.ErrSystemInCorruptedState, common.CreateSystemInCorruptedStateCmdFailure)

				var cmdFailure *common.CmdFailure
				Expect(errors.As(err, &cmdFailure)).To(BeTrue())
				Expect(cmdFailure.Code).To(Equal(config.ErrSystemInCorruptedState.Error()))
				Expect(cmdFailure.Message).To(Equal(common.ErrSystemInCorruptedStateMsg))
				Expect(cmdFailure.Severity).To(Equal(common.SeverityError))
				Expect(cmdFailure.SuppressCliOutput).To(BeFalse())
			})
		})
	})

	Describe("propPrint", func() {
		Describe("PrintProp", func() {
			It("orchestrates text colorization and printing", func() {
				message := "my-msg"
				prop := AddonStatusProp{Okay: new(false), Message: &message}

				printerMock := &mockObject{}
				printerMock.On(r.GetFunctionName(printerMock.PrintWarning), message).Once()

				sut := NewPropPrinter(printerMock)

				sut.PrintProp(prop)

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		DescribeTable("GetPropText", func(name string, value any, okay *nullableOkay, message *nullableMessage, colorizedResult string, expectedResult string) {
			prop := AddonStatusProp{Name: name, Value: value}
			if okay != nil {
				prop.Okay = &okay.value
			}
			if message != nil {
				prop.Message = &message.value
			}

			printerMock := &mockObject{}
			printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), colorizedResult).Return(colorizedResult)

			sut := NewPropPrinter(printerMock)

			result := sut.GetPropText(prop)

			Expect(result).To(Equal(expectedResult))
		},
			Entry("name, value", "test-prop", 123, nil, nil, "123", "test-prop: 123"),
			Entry("name, value, message", "test-prop", 123, nil, &nullableMessage{value: "my-msg"}, "my-msg", "my-msg"),
			Entry("name, value, okay", "test-prop", 123, &nullableOkay{value: true}, nil, "", "test-prop: 123"),
			Entry("name, value, message, okay", "test-prop", 123, &nullableOkay{value: true}, &nullableMessage{value: "my-msg"}, "", "my-msg"),
		)

		Describe("PrintPropText", func() {
			When("no okay-info is present", func() {
				It("prints neutral", func() {
					text := "test"

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), text).Once()

					sut := NewPropPrinter(printerMock)

					sut.PrintPropText(nil, text)

					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("okay", func() {
				It("prints success", func() {
					text := "test"
					okay := true

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintSuccess), text).Once()

					sut := NewPropPrinter(printerMock)

					sut.PrintPropText(&okay, text)

					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("not okay", func() {
				It("prints warning", func() {
					text := "test"
					okay := false

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintWarning), text).Once()

					sut := NewPropPrinter(printerMock)

					sut.PrintPropText(&okay, text)

					printerMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})

})
