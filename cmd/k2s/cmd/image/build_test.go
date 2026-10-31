//// SPDX-FileCopyrightText:  © 2024 The K2s Authors
//// SPDX-License-Identifier:   MIT

package image

import (
	"fmt"
	"os"

	"github.com/google/uuid"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/spf13/cobra"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("build", Ordered, func() {
	BeforeAll(func() {
		buildCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})

	Describe("extractBuildOptions", func() {
		When("no flags set", func() {
			It("build options are created with default values", func() {
				testCommand := createTestCobraCommand()

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.InputFolder).To(Equal(defaultInputFolder))
				Expect(actual.Dockerfile).To(Equal(defaultDockerfile))
				Expect(actual.Windows).To(Equal(defaultWindowsFlag))
				Expect(actual.Output).To(BeFalse())
				Expect(actual.Push).To(Equal(defaultPushFlag))
				Expect(actual.ImageName).To(Equal(defaultImageNameToBeBuilt))
				Expect(actual.ImageTag).To(Equal(defaultImageTagToBeBuilt))
				Expect(actual.BuildArgs).To(BeEmpty())
				Expect(actual.BuildArgs).NotTo(BeNil())
			})
		})

		When("input folder is set", func() {
			It("build options contain input folder", func() {
				expected := "/tmp/docker-build/testapp"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(inputFolderFlagName, expected)

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.InputFolder).To(Equal(expected))
			})
		})

		When("Dockerfile is set", func() {
			It("build options contain Dockerfile", func() {
				expected := "myDockerfile"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(dockerfileFlagName, expected)

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Dockerfile).To(Equal(expected))
			})
		})

		When("image is set", func() {
			It("build options contain image", func() {
				imageNameToBeBuilt := "my-image"
				imageTagToBeBuilt := "my-tag"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(imageNameFlagName, imageNameToBeBuilt)
				testCommand.Flags().Set(imageTagFlagName, imageTagToBeBuilt)

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.ImageName).To(Equal(imageNameToBeBuilt))
				Expect(actual.ImageTag).To(Equal(imageTagToBeBuilt))
			})
		})

		When("build args are set", func() {
			It("build options contain build args", func() {
				baseImageKey := "BaseImage"
				baseImageValue := "alpine"
				commitIdKey := "CommitId"
				commitIdValue := uuid.New().String()
				expected := make(map[string]string)
				expected[baseImageKey] = baseImageValue
				expected[commitIdKey] = commitIdValue
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(buildArgsFlagName, fmt.Sprintf("%s=%s", baseImageKey, baseImageValue))
				testCommand.Flags().Set(buildArgsFlagName, fmt.Sprintf("%s=%s", commitIdKey, commitIdValue))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.BuildArgs).To(Equal(expected))
			})
		})

		When("build args contain '=' in values", func() {
			It("preserves '=' in value", func() {
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(buildArgsFlagName, "CONN_STR=server=localhost;port=1234")

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.BuildArgs).To(Equal(map[string]string{
					"CONN_STR": "server=localhost;port=1234",
				}))
			})
		})

		When("build args format invalid", func() {
			It("returns error", func() {
				buildArgInIncorrectFormat := "DummyValue"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(buildArgsFlagName, buildArgInIncorrectFormat)

				actual, err := extractBuildOptions(testCommand)

				Expect(actual).To(BeNil())
				Expect(err).To(HaveOccurred())
			})
		})

		When("Windows build flag is set", func() {
			It("Windows build is enabled in build options", func() {
				expected := true
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(windowsFlagName, fmt.Sprintf("%t", expected))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Windows).To(Equal(expected))
			})
		})

		When("push enabled flag is set", func() {
			It("push is enabled in build options", func() {
				expected := true
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(pushFlagName, fmt.Sprintf("%t", expected))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Push).To(Equal(expected))
			})
		})

		When("output enabled flag is set", func() {
			It("output is enabled in build options", func() {
				expected := true
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(common.OutputFlagName, fmt.Sprintf("%t", expected))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Output).To(Equal(expected))
			})
		})
	})

	Describe("buildImage", func() {
		var mockImg *mockImageProvider
		var tempDir string

		BeforeEach(func() {
			mockImg = &mockImageProvider{}
		})

		AfterEach(func() {
			if tempDir != "" {
				_ = os.RemoveAll(tempDir)
			}
		})

		When("running on Linux-only installation and --windows flag is set", func() {
			It("returns an actionable error rejecting Windows images", func() {
				tempDir = setupTestCmdContext(buildCmd, mockImg, true, "control-plane")
				buildCmd.Flags().Set(windowsFlagName, "true")
				DeferCleanup(func() {
					buildCmd.Flags().Set(windowsFlagName, "false")
				})

				err := buildImage(buildCmd, []string{})

				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(Equal("building Windows container images is not supported on a Linux-only installation"))
			})
		})

		When("running on Linux-only installation with valid options", func() {
			It("routes to provider Image.Build successfully", func() {
				tempDir = setupTestCmdContext(buildCmd, mockImg, true, "control-plane")
				buildCmd.Flags().Set(windowsFlagName, "false")
				buildCmd.Flags().Set(inputFolderFlagName, "/tmp/test-build")
				buildCmd.Flags().Set(imageNameFlagName, "myimage")
				buildCmd.Flags().Set(imageTagFlagName, "v1")
				DeferCleanup(func() {
					buildCmd.Flags().Set(inputFolderFlagName, defaultInputFolder)
					buildCmd.Flags().Set(imageNameFlagName, defaultImageNameToBeBuilt)
					buildCmd.Flags().Set(imageTagFlagName, defaultImageTagToBeBuilt)
				})

				mockImg.On("Build", mock.MatchedBy(func(cfg provider.ImageBuildConfig) bool {
					return cfg.InputFolder == "/tmp/test-build" &&
						cfg.ImageName == "myimage" &&
						cfg.ImageTag == "v1" &&
						!cfg.Windows
				})).Return(nil)

				err := buildImage(buildCmd, []string{})

				Expect(err).ToNot(HaveOccurred())
				mockImg.AssertExpectations(GinkgoT())
			})
		})
	})
})

func newDefaultBuildOptions() *buildOptions {
	return &buildOptions{
		InputFolder: defaultInputFolder,
		Dockerfile:  defaultDockerfile,
		Windows:     defaultWindowsFlag,
		ImageName:   defaultImageNameToBeBuilt,
		ImageTag:    defaultImageTagToBeBuilt,
		Output:      false,
		Push:        defaultPushFlag,
		BuildArgs:   make(map[string]string),
	}
}

func createTestCobraCommand() *cobra.Command {
	testCommand := &cobra.Command{
		Use: "test-commmand",
	}
	addInitFlagsForBuildCommand(testCommand)

	testCommand.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)

	return testCommand
}
