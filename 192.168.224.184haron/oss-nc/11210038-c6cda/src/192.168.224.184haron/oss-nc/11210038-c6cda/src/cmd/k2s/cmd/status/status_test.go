// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package status_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/status"
	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/test/reflection"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) Println(mm ...any) {
	m.Called(mm...)
}

func (m *mockObject) PrintHeader(mm ...any) {
	m.Called(mm...)
}

func (m *mockObject) PrintSuccess(mm ...any) {
	m.Called(mm...)
}

func (m *mockObject) PrintInfoln(mm ...any) {
	m.Called(mm...)
}

func (m *mockObject) PrintWarning(mm ...any) {
	m.Called(mm...)
}

func (m *mockObject) PrintTreeListItems(items []string) {
	m.Called(items)
}

func (m *mockObject) PrintTableWithHeaders(table [][]string) {
	m.Called(table)
}

func (m *mockObject) PrintCyanFg(text string) string {
	args := m.Called(text)

	return args.String(0)
}

func (m *mockObject) PrintRedFg(text string) string {
	args := m.Called(text)

	return args.String(0)
}

func (m *mockObject) PrintGreenFg(text string) string {
	args := m.Called(text)

	return args.String(0)
}

func (m *mockObject) StartSpinner(mm ...any) (any, error) {
	args := m.Called(mm...)

	return args.Get(0), args.Error(1)
}

func (m *mockObject) Stop() error {
	args := m.Called()

	return args.Error(0)
}

func (m *mockObject) load() (*status.LoadedStatus, error) {
	args := m.Called()

	return args.Get(0).(*status.LoadedStatus), args.Error(1)
}

func (m *mockObject) marshalIndent(data any) ([]byte, error) {
	args := m.Called(data)

	return args.Get(0).([]byte), args.Error(1)
}

func TestStatusPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status pkg Unit Tests", Label("unit", "ci", "status"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("status pkg", func() {
	Describe("print", func() {
		Describe("JsonPrinter", func() {
			Describe("Print", func() {
				When("load error occurrs", func() {
					It("returns the error", func() {
						expectedErr := errors.New("oops")
						var nilStatus *status.LoadedStatus

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(nilStatus, expectedErr)

						sut := status.NewJsonPrinter(nil, nil, nil, loadMock.load)

						err := sut.Print()

						Expect(err).To(MatchError(expectedErr))
					})
				})

				When("marshal error occurrs", func() {
					It("returns the error", func() {
						expectedErr := errors.New("oops")
						loadedStatus := &status.LoadedStatus{}
						runtimeConfig := config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("", false, "", false, false), nil)

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

						marshalMock := &mockObject{}
						marshalMock.On(reflection.GetFunctionName(marshalMock.marshalIndent), mock.AnythingOfType("PrintStatus")).Return([]byte{}, expectedErr)

						sut := status.NewJsonPrinter(runtimeConfig, nil, marshalMock.marshalIndent, loadMock.load)

						err := sut.Print()

						Expect(err).To(MatchError(expectedErr))
					})
				})

				When("status contains a failure", func() {
					It("prints the status and returns the failure", func() {
						failureCode := "omg"
						loadedStatus := &status.LoadedStatus{
							CmdResult: common.CmdResult{
								Failure: &common.CmdFailure{
									Code: failureCode,
								},
							},
							RunningState: &status.RunningState{IsRunning: true},
							Nodes:        []status.Node{{Name: "n1"}},
							Pods:         []status.Pod{{Name: "p1"}},
							K8sVersionInfo: &status.K8sVersionInfo{
								K8sServerVersion: "123",
								K8sClientVersion: "321",
							},
						}
						runtimeConfig := config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("test-name", true, "test-version", false, false), nil)
						jsonStatus := "status"

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

						marshalMock := &mockObject{}
						marshalMock.On(reflection.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(data any) bool {
							status, ok := data.(status.PrintStatus)
							if !ok {
								return false
							}
							return *status.Error == failureCode &&
								status.SetupInfo.Name == string(runtimeConfig.InstallConfig().SetupName()) &&
								status.SetupInfo.Version == runtimeConfig.InstallConfig().Version() &&
								status.SetupInfo.LinuxOnly == runtimeConfig.InstallConfig().LinuxOnly() &&
								status.RunningState.IsRunning &&
								status.Nodes[0].Name == "n1" &&
								status.Pods[0].Name == "p1" &&
								status.K8sVersionInfo.K8sClientVersion == "321" &&
								status.K8sVersionInfo.K8sServerVersion == "123"
						})).Return([]byte(jsonStatus), nil)

						printerMock := &mockObject{}
						printerMock.On(reflection.GetFunctionName(printerMock.Println), jsonStatus).Once()

						sut := status.NewJsonPrinter(runtimeConfig, printerMock.Println, marshalMock.marshalIndent, loadMock.load)

						err := sut.Print()

						var cmdFailure *common.CmdFailure
						Expect(errors.As(err, &cmdFailure)).To(BeTrue())
						Expect(cmdFailure.Code).To(Equal(failureCode))
						Expect(cmdFailure.SuppressCliOutput).To(BeTrue())

						printerMock.AssertExpectations(GinkgoT())
					})
				})

				When("successful", func() {
					It("prints the status and returns nil", func() {
						loadedStatus := &status.LoadedStatus{
							CmdResult:    common.CmdResult{},
							RunningState: &status.RunningState{IsRunning: true},
							Nodes:        []status.Node{{Name: "n1"}},
							Pods:         []status.Pod{{Name: "p1"}},
							K8sVersionInfo: &status.K8sVersionInfo{
								K8sServerVersion: "123",
								K8sClientVersion: "321",
							},
						}
						runtimeConfig := config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("test-name", true, "test-version", false, false), nil)
						jsonStatus := "status"

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

						marshalMock := &mockObject{}
						marshalMock.On(reflection.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(data any) bool {
							status, ok := data.(status.PrintStatus)
							if !ok {
								return false
							}
							return status.Error == nil &&
								status.SetupInfo.Name == string(runtimeConfig.InstallConfig().SetupName()) &&
								status.SetupInfo.Version == runtimeConfig.InstallConfig().Version() &&
								status.SetupInfo.LinuxOnly == runtimeConfig.InstallConfig().LinuxOnly() &&
								status.RunningState.IsRunning &&
								status.Nodes[0].Name == "n1" &&
								status.Pods[0].Name == "p1" &&
								status.K8sVersionInfo.K8sClientVersion == "321" &&
								status.K8sVersionInfo.K8sServerVersion == "123"
						})).Return([]byte(jsonStatus), nil)

						printerMock := &mockObject{}
						printerMock.On(reflection.GetFunctionName(printerMock.Println), jsonStatus).Once()

						sut := status.NewJsonPrinter(runtimeConfig, printerMock.Println, marshalMock.marshalIndent, loadMock.load)

						err := sut.Print()

						Expect(err).ToNot(HaveOccurred())

						printerMock.AssertExpectations(GinkgoT())
					})
				})
			})
		})

		Describe("UserFriendlyPrinter", func() {
			Describe("Print", func() {
				When("start spinner error occurred", func() {
					It("returns the error", func() {
						expectedErr := errors.New("oops")

						printerMock := &mockObject{}
						printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(nil, expectedErr)

						sut := status.NewUserFriendlyPrinter(nil, false, printerMock, nil)

						err := sut.Print()

						Expect(err).To(MatchError(expectedErr))
					})
				})

				When("load error occurred", func() {
					It("returns the error", func() {
						expectedErr := errors.New("oops")
						var nilStatus *status.LoadedStatus

						spinnerMock := &mockObject{}
						spinnerMock.On(reflection.GetFunctionName(spinnerMock.Stop)).Return(nil)

						printerMock := &mockObject{}
						printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(nilStatus, expectedErr)

						sut := status.NewUserFriendlyPrinter(nil, false, printerMock, loadMock.load)

						err := sut.Print()

						Expect(err).To(MatchError(expectedErr))
					})
				})

				When("status contains failure", func() {
					It("returns the failure", func() {
						expectedFailure := &common.CmdFailure{
							Severity: common.SeverityError,
							Code:     "test-code",
							Message:  "test-msg",
						}
						loadedStatus := &status.LoadedStatus{
							CmdResult: common.CmdResult{
								Failure: expectedFailure,
							},
						}

						spinnerMock := &mockObject{}
						spinnerMock.On(reflection.GetFunctionName(spinnerMock.Stop)).Return(nil)

						printerMock := &mockObject{}
						printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

						sut := status.NewUserFriendlyPrinter(nil, false, printerMock, loadMock.load)

						err := sut.Print()

						Expect(err).To(MatchError(expectedFailure))
					})
				})

				When("status does not contain running state info", func() {
					It("returns an error", func() {
						loadedStatus := &status.LoadedStatus{
							CmdResult: common.CmdResult{},
						}

						spinnerMock := &mockObject{}
						spinnerMock.On(reflection.GetFunctionName(spinnerMock.Stop)).Return(nil)

						printerMock := &mockObject{}
						printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

						sut := status.NewUserFriendlyPrinter(nil, false, printerMock, loadMock.load)

						err := sut.Print()

						Expect(err).To(MatchError(ContainSubstring("no running state info")))
					})
				})

				When("status does not contain K8s version info", func() {
					It("returns an error", func() {
						runtimeConfig := config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("", false, "", false, false), nil)
						loadedStatus := &status.LoadedStatus{
							CmdResult: common.CmdResult{},
							RunningState: &status.RunningState{
								IsRunning: true,
							},
						}

						spinnerMock := &mockObject{}
						spinnerMock.On(reflection.GetFunctionName(spinnerMock.Stop)).Return(nil)

						printerMock := &mockObject{}
						printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
						printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
						printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
						printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
						printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything)

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

						sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

						err := sut.Print()

						Expect(err).To(MatchError(ContainSubstring("no K8s version info")))
					})
				})

				When("successful", func() {
					var runtimeConfig *config.K2sRuntimeConfig
					var loadedStatus *status.LoadedStatus
					var spinnerMock *mockObject

					BeforeEach(func() {
						runtimeConfig = config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("test-name", false, "test-version", false, false), nil)
						loadedStatus = &status.LoadedStatus{
							CmdResult:    common.CmdResult{},
							RunningState: &status.RunningState{},
						}
						spinnerMock = &mockObject{}
						spinnerMock.On(reflection.GetFunctionName(spinnerMock.Stop)).Return(nil)
					})

					It("prints the header", func() {
						printerMock := &mockObject{}
						printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
						printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), "K2s SYSTEM STATUS").Once()
						printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
						printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
						printerMock.On(reflection.GetFunctionName(printerMock.PrintInfoln), mock.Anything)
						printerMock.On(reflection.GetFunctionName(printerMock.PrintTreeListItems), mock.Anything)

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

						sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

						err := sut.Print()

						Expect(err).ToNot(HaveOccurred())

						printerMock.AssertExpectations(GinkgoT())
					})

					It("prints setup name and version", func() {
						printerMock := &mockObject{}
						printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
						printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
						printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "test-name").Return("test-name-colored")
						printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "test-version").Return("test-version-colored")
						printerMock.On(reflection.GetFunctionName(printerMock.Println), "Setup: 'test-name-colored', Version: 'test-version-colored'").Once()
						printerMock.On(reflection.GetFunctionName(printerMock.PrintInfoln), mock.Anything)
						printerMock.On(reflection.GetFunctionName(printerMock.PrintTreeListItems), mock.Anything)

						loadMock := &mockObject{}
						loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

						sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

						err := sut.Print()

						Expect(err).ToNot(HaveOccurred())

						printerMock.AssertExpectations(GinkgoT())
					})

					When("setup is Linux-only", func() {
						BeforeEach(func() {
							runtimeConfig = config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig("test-name", true, "test-version", false, false), nil)
						})

						It("prints setup name with Linux-only hint and version", func() {
							printerMock := &mockObject{}
							printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "test-name (Linux-only)").Return("test-name-colored (Linux-only)")
							printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "test-version").Return("test-version-colored")
							printerMock.On(reflection.GetFunctionName(printerMock.Println), "Setup: 'test-name-colored (Linux-only)', Version: 'test-version-colored'").Once()
							printerMock.On(reflection.GetFunctionName(printerMock.PrintInfoln), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintTreeListItems), mock.Anything)

							loadMock := &mockObject{}
							loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

							sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

							err := sut.Print()

							Expect(err).ToNot(HaveOccurred())

							printerMock.AssertExpectations(GinkgoT())
						})
					})

					When("system not running", func() {
						BeforeEach(func() {
							loadedStatus.RunningState.IsRunning = false
							loadedStatus.RunningState.Issues = []string{"i-1", "i-2"}
						})

						It("prints system-not-running info", func() {
							printerMock := &mockObject{}
							printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
							printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintInfoln), mock.MatchedBy(func(info string) bool {
								return Expect(info).To(ContainSubstring("system is stopped"))
							})).Once()
							printerMock.On(reflection.GetFunctionName(printerMock.PrintTreeListItems), mock.Anything)

							loadMock := &mockObject{}
							loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

							sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

							err := sut.Print()

							Expect(err).ToNot(HaveOccurred())

							printerMock.AssertExpectations(GinkgoT())
						})

						It("prints issues", func() {
							printerMock := &mockObject{}
							printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
							printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintInfoln), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintTreeListItems), mock.MatchedBy(func(items []string) bool {
								return Expect(items).To(Equal(loadedStatus.RunningState.Issues))
							})).Once()

							loadMock := &mockObject{}
							loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

							sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

							err := sut.Print()

							Expect(err).ToNot(HaveOccurred())

							printerMock.AssertExpectations(GinkgoT())
						})
					})

					When("system is running", func() {
						BeforeEach(func() {
							loadedStatus.RunningState.IsRunning = true
							loadedStatus.K8sVersionInfo = &status.K8sVersionInfo{
								K8sServerVersion: "s-1",
								K8sClientVersion: "c-1",
							}
						})

						It("prints system running info", func() {
							printerMock := &mockObject{}
							printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
							printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), "The system is running").Once()

							loadMock := &mockObject{}
							loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

							sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

							err := sut.Print()

							Expect(err).ToNot(HaveOccurred())

							printerMock.AssertExpectations(GinkgoT())
						})

						When("setup is build-only", func() {
							BeforeEach(func() {
								runtimeConfig = config.NewK2sRuntimeConfig(nil, config.NewK2sInstallConfig(definitions.SetupNameBuildOnlyEnv, false, "test-version", false, false), nil)
								loadedStatus.K8sVersionInfo = nil
							})

							It("returns without printing K8s components status", func() {
								printerMock := &mockObject{}
								printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
								printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything)

								loadMock := &mockObject{}
								loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

								sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

								err := sut.Print()

								Expect(err).ToNot(HaveOccurred())

								printerMock.AssertExpectations(GinkgoT())
							})
						})

						It("prints K8s versions", func() {
							printerMock := &mockObject{}
							printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
							printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "test-name").Return("")
							printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "test-version").Return("")
							printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "s-1").Return("s-1-colored")
							printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), "c-1").Return("c-1-colored")
							printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything).Times(2)
							printerMock.On(reflection.GetFunctionName(printerMock.Println), "K8s server version: 's-1-colored'").Once()
							printerMock.On(reflection.GetFunctionName(printerMock.Println), "K8s client version: 'c-1-colored'").Once()
							printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything)

							loadMock := &mockObject{}
							loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

							sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

							err := sut.Print()

							Expect(err).ToNot(HaveOccurred())

							printerMock.AssertExpectations(GinkgoT())
						})

						When("Nodes with different ready states exist", func() {
							BeforeEach(func() {
								loadedStatus.Nodes = []status.Node{
									{
										Name:             "n1",
										Status:           "good",
										IsReady:          true,
										Role:             "good-one",
										Age:              "new",
										KubeletVersion:   "k1",
										KernelVersion:    "k2",
										OsImage:          "os-1",
										ContainerRuntime: "c-1",
										InternalIp:       "ip-1",
										Capacity: status.Capacity{
											Cpu:     "3",
											Memory:  "4Gi",
											Storage: "5Ti",
										},
									},
									{
										Name:             "n2",
										Status:           "bad",
										IsReady:          false,
										Role:             "bad-one",
										Age:              "old",
										KubeletVersion:   "k99",
										KernelVersion:    "k3",
										OsImage:          "os-2",
										ContainerRuntime: "c-2",
										InternalIp:       "ip-2",
										Capacity: status.Capacity{
											Cpu:     "6",
											Memory:  "7Gi",
											Storage: "8Ti",
										},
									},
								}
							})

							It("prints Nodes status table", func() {
								expectedTable := [][]string{
									{"STATUS", "NAME", "ROLE", "AGE", "VERSION", "CPUs", "RAM", "DISK"},
									{"good-green", "n1", "good-one", "new", "k1", "3", "4GiB", "5TiB"},
									{"bad-red", "n2", "bad-one", "old", "k99", "6", "7GiB", "8TiB"},
								}

								printerMock := &mockObject{}
								printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
								printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), "good").Return("good-green")
								printerMock.On(reflection.GetFunctionName(printerMock.PrintRedFg), "bad").Return("bad-red")
								printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), expectedTable).Once()
								printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), mock.Anything)

								loadMock := &mockObject{}
								loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

								sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

								err := sut.Print()

								Expect(err).ToNot(HaveOccurred())

								printerMock.AssertExpectations(GinkgoT())
							})

							It("prints a warning that not all Nodes are ready", func() {
								printerMock := &mockObject{}
								printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
								printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), mock.Anything).Return("")
								printerMock.On(reflection.GetFunctionName(printerMock.PrintRedFg), mock.Anything).Return("")
								printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), mock.Anything)
								printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), "Some nodes are not ready").Once()

								loadMock := &mockObject{}
								loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

								sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

								err := sut.Print()

								Expect(err).ToNot(HaveOccurred())

								printerMock.AssertExpectations(GinkgoT())
							})

							When("additional info shall be printed", func() {
								It("prints Nodes status table with additional columns", func() {
									expectedTable := [][]string{
										{"STATUS", "NAME", "ROLE", "AGE", "VERSION", "CPUs", "RAM", "DISK", "INTERNAL-IP", "OS-IMAGE", "KERNEL-VERSION", "CONTAINER-RUNTIME"},
										{"good-green", "n1", "good-one", "new", "k1", "3", "4GiB", "5TiB", "ip-1", "os-1", "k2", "c-1"},
										{"bad-red", "n2", "bad-one", "old", "k99", "6", "7GiB", "8TiB", "ip-2", "os-2", "k3", "c-2"},
									}

									printerMock := &mockObject{}
									printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
									printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
									printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
									printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
									printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything)
									printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), "good").Return("good-green")
									printerMock.On(reflection.GetFunctionName(printerMock.PrintRedFg), "bad").Return("bad-red")
									printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), expectedTable).Once()
									printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), mock.Anything)

									loadMock := &mockObject{}
									loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

									sut := status.NewUserFriendlyPrinter(runtimeConfig, true, printerMock, loadMock.load)

									err := sut.Print()

									Expect(err).ToNot(HaveOccurred())

									printerMock.AssertExpectations(GinkgoT())
								})
							})

							When("all Nodes are ready", func() {
								BeforeEach(func() {
									loadedStatus.Nodes = []status.Node{
										{
											Name:    "n1",
											Status:  "good",
											IsReady: true,
											Capacity: status.Capacity{
												Storage: "1B",
												Memory:  "2B",
											},
										},
									}
								})

								It("prints a success info that all Nodes are ready", func() {
									printerMock := &mockObject{}
									printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
									printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
									printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
									printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
									printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything).Once()
									printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), "All nodes are ready").Once()
									printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), mock.Anything).Return("")
									printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), mock.Anything)

									loadMock := &mockObject{}
									loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

									sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

									err := sut.Print()

									Expect(err).ToNot(HaveOccurred())

									printerMock.AssertExpectations(GinkgoT())
								})

								When("Pods with different running states exist", func() {
									BeforeEach(func() {
										loadedStatus.Pods = []status.Pod{
											{
												Name:      "p-1",
												Status:    "running",
												Namespace: "n-1",
												Ready:     "yes",
												Restarts:  "none",
												Age:       "new",
												Ip:        "i-1",
												Node:      "n1",
												IsRunning: true,
											},
											{
												Name:      "p-2",
												Status:    "failed",
												Namespace: "n-2",
												Ready:     "no",
												Restarts:  "many",
												Age:       "old",
												Ip:        "i-2",
												Node:      "n1",
												IsRunning: false,
											},
										}
									})

									It("prints Pods status table", func() {
										expectedPodsTable := [][]string{
											{"STATUS", "NAME", "READY", "RESTARTS", "AGE"},
											{"running-green", "p-1", "yes", "none", "new"},
											{"failed-red", "p-2", "no", "many", "old"},
										}

										printerMock := &mockObject{}
										printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
										printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), "good").Return("good-green")
										printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), "running").Return("running-green")
										printerMock.On(reflection.GetFunctionName(printerMock.PrintRedFg), "failed").Return("failed-red")
										printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), mock.Anything).Once()
										printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), expectedPodsTable).Once()
										printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), mock.Anything)

										loadMock := &mockObject{}
										loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

										sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

										err := sut.Print()

										Expect(err).ToNot(HaveOccurred())

										printerMock.AssertExpectations(GinkgoT())
									})

									It("prints a warning that not all Pods are running", func() {
										printerMock := &mockObject{}
										printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
										printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), mock.Anything).Return("")
										printerMock.On(reflection.GetFunctionName(printerMock.PrintRedFg), mock.Anything).Return("")
										printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), mock.Anything)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), "Some essential Pods are not running").Once()

										loadMock := &mockObject{}
										loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

										sut := status.NewUserFriendlyPrinter(runtimeConfig, false, printerMock, loadMock.load)

										err := sut.Print()

										Expect(err).ToNot(HaveOccurred())

										printerMock.AssertExpectations(GinkgoT())
									})

									When("additional info shall be printed", func() {
										It("prints Pods status table with additional columns", func() {
											expectedPodsTable := [][]string{
												{"STATUS", "NAMESPACE", "NAME", "READY", "RESTARTS", "AGE", "IP", "NODE"},
												{"running-green", "n-1", "p-1", "yes", "none", "new", "i-1", "n1"},
												{"failed-red", "n-2", "p-2", "no", "many", "old", "i-2", "n1"},
											}

											printerMock := &mockObject{}
											printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
											printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
											printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
											printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
											printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything)
											printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), "good").Return("good-green")
											printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), "running").Return("running-green")
											printerMock.On(reflection.GetFunctionName(printerMock.PrintRedFg), "failed").Return("failed-red")
											printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), mock.Anything).Once()
											printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), expectedPodsTable).Once()
											printerMock.On(reflection.GetFunctionName(printerMock.PrintWarning), mock.Anything)

											loadMock := &mockObject{}
											loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

											sut := status.NewUserFriendlyPrinter(runtimeConfig, true, printerMock, loadMock.load)

											err := sut.Print()

											Expect(err).ToNot(HaveOccurred())

											printerMock.AssertExpectations(GinkgoT())
										})
									})
								})

								When("all Pods are running", func() {
									BeforeEach(func() {
										loadedStatus.Pods = []status.Pod{
											{
												Name:      "p-1",
												Status:    "running",
												Namespace: "n-1",
												Ready:     "yes",
												Restarts:  "none",
												Age:       "new",
												Ip:        "i-1",
												Node:      "n1",
												IsRunning: true,
											},
										}
									})

									It("prints a success info that all Pods are running", func() {
										printerMock := &mockObject{}
										printerMock.On(reflection.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintHeader), mock.Anything)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("")
										printerMock.On(reflection.GetFunctionName(printerMock.Println), mock.Anything)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.Anything).Times(2)
										printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), "All essential Pods are running").Once()
										printerMock.On(reflection.GetFunctionName(printerMock.PrintGreenFg), mock.Anything).Return("")
										printerMock.On(reflection.GetFunctionName(printerMock.PrintTableWithHeaders), mock.Anything)

										loadMock := &mockObject{}
										loadMock.On(reflection.GetFunctionName(loadMock.load)).Return(loadedStatus, nil)

										sut := status.NewUserFriendlyPrinter(runtimeConfig, true, printerMock, loadMock.load)

										err := sut.Print()

										Expect(err).ToNot(HaveOccurred())

										printerMock.AssertExpectations(GinkgoT())
									})
								})
							})
						})
					})
				})
			})
		})
	})
})
