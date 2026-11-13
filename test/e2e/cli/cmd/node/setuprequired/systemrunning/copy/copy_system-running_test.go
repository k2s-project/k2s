// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package copy

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
	framework_os "github.com/k2s-project/k2s/test/framework/os"
)

type sshExecutor struct {
	ipAddress  string
	remoteUser string
	keyPath    string
	executor   *framework_os.CliExecutor
}

var suite *framework.K2sTestSuite
var skipWinNodeTests bool

func TestCopy(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node copy Acceptance Tests", Label("cli", "node", "copy", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))

	// TODO: remove when adding Win nodes is supported
	skipWinNodeTests = true // suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

// TODO: test different path versions
// TODO: test large files

var _ = Describe("node copy", Ordered, func() {
	Describe("to node", func() {
		When("source does not exist", func() {
			DescribeTable("exits with failure", func(ctx context.Context, source string) {
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", "", "-s", source, "-t", "", "-u", "", "-o")

				Expect(output).To(SatisfyAll(
					MatchRegexp("ERROR"),
					MatchRegexp("failed to copy"),
					MatchRegexp("source .+ does not exist"),
				))
			},
				Entry("file not existing", "c:\\non-existent.file"),
				Entry("folder not existing", "c:\\non-existent\\folder\\"),
			)
		})

		When("node is Linux node", Label("linux-node"), func() {
			const remoteUser = "remote"

			var nodeIpAddress string
			var localTempDir string

			var remoteTempDirName string
			var remoteTempDir string

			var sshExec *sshExecutor

			BeforeEach(func(ctx context.Context) {
				localTempDir = GinkgoT().TempDir()
				remoteTempDirName = fmt.Sprintf("test_%d/", GinkgoRandomSeed())
				remoteTempDir = "~/" + remoteTempDirName

				nodeIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

				GinkgoWriter.Println("Using control-plane node IP address <", nodeIpAddress, ">")

				sshExec = &sshExecutor{
					ipAddress:  nodeIpAddress,
					remoteUser: "remote",
					keyPath:    "~/.ssh\\k2s\\id_rsa",
					executor:   suite.Cli("ssh.exe"),
				}

				GinkgoWriter.Println("Creating remote temp dir <", remoteTempDir, ">")

				sshExec.mustExecEventually(ctx, "mkdir -p "+remoteTempDir)
			})

			AfterEach(func(ctx context.Context) {
				GinkgoWriter.Println("Removing remote temp dir <", remoteTempDir, ">")

				sshExec.exec(ctx, "rm -rf "+remoteTempDir)
			})

			When("source is a file", func() {
				const sourceFileName = "test.file"
				const sourceFileContent = "This is the test file content.\n"

				var sourceFile string

				BeforeEach(func(ctx context.Context) {
					sourceFile = filepath.Join(localTempDir, sourceFileName)

					Expect(os.WriteFile(sourceFile, []byte(sourceFileContent), fs.ModePerm)).To(Succeed())

					GinkgoWriter.Println("Local test file (source) <", sourceFile, "> written")
				})

				When("target is existing", func() {
					When("target is a file", func() {
						var existingRemoteFile string

						BeforeEach(func(ctx context.Context) {
							existingRemoteFile = path.Join(remoteTempDir, sourceFileName)

							GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

							sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
						})

						It("overwrites the existing file", func(ctx context.Context) {
							targetFile := existingRemoteFile

							output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'k2s node copy' completed"))

							content := sshExec.mustExecEventually(ctx, "cat "+targetFile)

							Expect(content).To(Equal(sourceFileContent))
						})

						When("target is file name only", func() {
							BeforeEach(func(ctx context.Context) {
								existingRemoteFile = sourceFileName

								GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

								sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
							})

							AfterEach(func(ctx context.Context) {
								GinkgoWriter.Println("Removing file <", existingRemoteFile, ">")

								sshExec.exec(ctx, "rm -rf "+existingRemoteFile)
							})

							It("overwrites existing file in home dir", func(ctx context.Context) {
								targetFile := sourceFileName

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content := sshExec.mustExecEventually(ctx, "cat "+targetFile)

								Expect(content).To(Equal(sourceFileContent))
							})
						})
					})

					When("target is a folder", func() {
						When("file with same name exists in target", func() {
							var existingRemoteFile string

							BeforeEach(func(ctx context.Context) {
								existingRemoteFile = path.Join(remoteTempDir, sourceFileName)

								GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

								sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
							})

							It("overwrites the existing file", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content := sshExec.mustExecEventually(ctx, "cat "+existingRemoteFile)

								Expect(content).To(Equal(sourceFileContent))
							})

							When("target is tilde (~/) only", func() {
								BeforeEach(func(ctx context.Context) {
									existingRemoteFile = "~/" + sourceFileName

									GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

									sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
								})

								AfterEach(func(ctx context.Context) {
									GinkgoWriter.Println("Removing file <", existingRemoteFile, ">")

									sshExec.exec(ctx, "rm -rf "+existingRemoteFile)
								})

								It("overwrites the existing file in the home dir", func(ctx context.Context) {
									targetFolder := "~/"

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									content := sshExec.mustExecEventually(ctx, "cat "+existingRemoteFile)

									Expect(content).To(Equal(sourceFileContent))
								})
							})
						})

						When("file with same name does not exist in target", func() {
							It("copies the file to target", func(ctx context.Context) {
								targetFolder := remoteTempDir
								expectedTargetFile := path.Join(remoteTempDir, sourceFileName)

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content := sshExec.mustExecEventually(ctx, "cat "+expectedTargetFile)

								Expect(content).To(Equal(sourceFileContent))
							})

							When("target is tilde (~/) only", func() {
								var expectedRemoteFile string

								BeforeEach(func() {
									expectedRemoteFile = "~/" + sourceFileName
								})

								AfterEach(func(ctx context.Context) {
									GinkgoWriter.Println("Removing file <", expectedRemoteFile, ">")

									sshExec.exec(ctx, "rm -rf "+expectedRemoteFile)
								})

								It("copies the file to home dir", func(ctx context.Context) {
									targetFolder := "~/"

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									content := sshExec.mustExecEventually(ctx, "cat "+expectedRemoteFile)

									Expect(content).To(Equal(sourceFileContent))
								})
							})
						})
					})
				})

				When("target is not existing", func() {
					When("target parent folder is existing", func() {
						It("creates the target file and copies the content", func(ctx context.Context) {
							targetFile := path.Join(remoteTempDir, sourceFileName)

							output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'k2s node copy' completed"))

							content := sshExec.mustExecEventually(ctx, "cat "+targetFile)

							Expect(content).To(Equal(sourceFileContent))
						})
					})

					When("target parent folder is not existing", func() {
						It("exits with failure", func(ctx context.Context) {
							targetFile := path.Join(remoteTempDir, "non-existent", sourceFileName)

							output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("parent .+ not existing"),
							))
						})
					})

					When("target is file name only", func() {
						var expectedRemoteFile string

						BeforeEach(func() {
							expectedRemoteFile = sourceFileName
						})

						AfterEach(func(ctx context.Context) {
							GinkgoWriter.Println("Removing file <", expectedRemoteFile, ">")

							sshExec.exec(ctx, "rm -rf "+expectedRemoteFile)
						})

						It("copies the file to home dir", func(ctx context.Context) {
							targetFile := sourceFileName

							output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'k2s node copy' completed"))

							content := sshExec.mustExecEventually(ctx, "cat "+expectedRemoteFile)

							Expect(content).To(Equal(sourceFileContent))
						})
					})
				})
			})

			When("source is a folder", func() {
				const sourceFolderName = "test-folder"
				const sourceSubFolderName = "test-sub-folder"

				var sourceFileInfos = []struct {
					name      string
					subFolder string
					content   string
				}{
					{name: "test-1-file", subFolder: "", content: "test-content-1\n"},
					{name: "test-2-file", subFolder: sourceSubFolderName, content: "test-content-2\n"},
					{name: "test-3-file", subFolder: "", content: "test-content-3\n"},
				}

				var sourceFolder string

				BeforeEach(func(ctx context.Context) {
					sourceFolder = filepath.Join(localTempDir, sourceFolderName)

					GinkgoWriter.Println("Creating local source folder <", sourceFolder, ">")
					Expect(os.MkdirAll(sourceFolder, fs.ModePerm)).To(Succeed())

					for _, fileInfo := range sourceFileInfos {
						dir := sourceFolder

						if fileInfo.subFolder != "" {
							dir = filepath.Join(sourceFolder, fileInfo.subFolder)

							GinkgoWriter.Println("Creating local source sub folder <", dir, ">")
							Expect(os.MkdirAll(dir, fs.ModePerm)).To(Succeed())
						}

						filePath := filepath.Join(dir, fileInfo.name)

						GinkgoWriter.Println("Writing local source file <", filePath, ">")
						Expect(os.WriteFile(filePath, []byte(fileInfo.content), fs.ModePerm)).To(Succeed())
					}
				})

				When("target is existing", func() {
					When("target is a file", func() {
						var existingRemoteFile string

						BeforeEach(func(ctx context.Context) {
							existingRemoteFile = path.Join(remoteTempDir, "some-file")

							GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

							sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
						})

						It("exits with failure", func(ctx context.Context) {
							targetFile := existingRemoteFile

							output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("target .+ is a file"),
							))
						})
					})

					When("target is a folder", func() {
						When("source folder name exists in target", func() {
							var existingRemoteFolder string

							BeforeEach(func(ctx context.Context) {
								existingRemoteFolder = path.Join(remoteTempDir, sourceFolderName)

								GinkgoWriter.Println("Creating remote folder <", existingRemoteFolder, ">")

								sshExec.mustExecEventually(ctx, "mkdir -p "+existingRemoteFolder)
							})

							It("copies contents of source folder to existing folder in target dir", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								for _, fileInfo := range sourceFileInfos {
									remotePath := path.Join(existingRemoteFolder, fileInfo.subFolder, fileInfo.name)
									content := sshExec.mustExecEventually(ctx, "cat "+remotePath)

									Expect(content).To(Equal(fileInfo.content))
								}
							})

							When("folder with same name contains files with same name", func() {
								BeforeEach(func(ctx context.Context) {
									for _, fileInfo := range sourceFileInfos {
										dir := existingRemoteFolder

										if fileInfo.subFolder != "" {
											dir = path.Join(dir, fileInfo.subFolder)

											GinkgoWriter.Println("Creating remote target sub folder <", dir, ">")
											sshExec.mustExecEventually(ctx, "mkdir -p "+dir)
										}

										filePath := path.Join(dir, fileInfo.name)

										GinkgoWriter.Println("Writing remote target file <", filePath, ">")
										sshExec.mustExecEventually(ctx, "echo 'existing content' > "+filePath)
									}
								})

								It("copies contents of source folder to existing folder in target dir, overwriting existing files", func(ctx context.Context) {
									targetFolder := remoteTempDir

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									for _, fileInfo := range sourceFileInfos {
										remotePath := path.Join(existingRemoteFolder, fileInfo.subFolder, fileInfo.name)
										content := sshExec.mustExecEventually(ctx, "cat "+remotePath)

										Expect(content).To(Equal(fileInfo.content))
									}
								})
							})
						})

						When("source folder name does not exist in target", func() {
							It("copies the folder to target", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								for _, fileInfo := range sourceFileInfos {
									remotePath := path.Join(remoteTempDir, sourceFolderName, fileInfo.subFolder, fileInfo.name)
									content := sshExec.mustExecEventually(ctx, "cat "+remotePath)

									Expect(content).To(Equal(fileInfo.content))
								}
							})
						})
					})
				})

				When("target is not existing", func() {
					When("target parent folder is existing", func() {
						It("creates target dir and copies contents of source folder", func(ctx context.Context) {
							targetFolder := path.Join(remoteTempDir, sourceFolderName)

							output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'k2s node copy' completed"))

							for _, fileInfo := range sourceFileInfos {
								remotePath := path.Join(targetFolder, fileInfo.subFolder, fileInfo.name)
								content := sshExec.mustExecEventually(ctx, "cat "+remotePath)

								Expect(content).To(Equal(fileInfo.content))
							}
						})
					})

					When("target parent folder is not existing", func() {
						It("exits with failure", func(ctx context.Context) {
							targetFolder := path.Join(remoteTempDir, "non-existent-parent", sourceFolderName)

							output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("remote parent not existing"),
							))
						})
					})
				})
			})
		})

		When("node is Windows node", Label("windows-node"), func() {
			const remoteUser = "administrator"

			var nodeIpAddress string
			var localTempDir string

			var remoteTempDirName string
			var remoteTempDir string

			var sshExec *sshExecutor

			BeforeEach(func(ctx context.Context) {
				if skipWinNodeTests {
					Skip("Windows node tests are skipped")
				}

				localTempDir = GinkgoT().TempDir()
				remoteTempDirName = fmt.Sprintf("test_%d/", GinkgoRandomSeed())
				remoteTempDir = filepath.Join("C:\\Users", remoteUser, remoteTempDirName)

				// TODO: set when adding Win nodes is supported
				nodeIpAddress = ""

				GinkgoWriter.Println("Using windows node IP address <", nodeIpAddress, ">")

				sshExec = &sshExecutor{
					ipAddress:  nodeIpAddress,
					remoteUser: remoteUser,
					keyPath:    "~/.ssh\\k2s\\id_rsa",
					executor:   suite.Cli("ssh.exe"),
				}

				GinkgoWriter.Println("Creating remote temp dir <", remoteTempDir, ">")

				sshExec.mustExecEventually(ctx, "mkdir "+remoteTempDir)
			})

			AfterEach(func(ctx context.Context) {
				if skipWinNodeTests {
					Skip("Windows node tests are skipped")
				}

				GinkgoWriter.Println("Removing remote temp dir <", remoteTempDir, ">")

				sshExec.exec(ctx, "rd /s /q "+remoteTempDir)
			})

			When("source is a file", func() {
				const sourceFileName = "test.file"
				const sourceFileContent = "This is the test file content.\r\n"

				var sourceFile string

				BeforeEach(func(ctx context.Context) {
					sourceFile = filepath.Join(localTempDir, sourceFileName)

					Expect(os.WriteFile(sourceFile, []byte(sourceFileContent), fs.ModePerm)).To(Succeed())

					GinkgoWriter.Println("Local test file (source) <", sourceFile, "> written")
				})

				When("target is existing", func() {
					When("target is a file", func() {
						var existingRemoteFile string

						BeforeEach(func(ctx context.Context) {
							existingRemoteFile = filepath.Join(remoteTempDir, sourceFileName)

							GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

							sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
						})

						It("overwrites the existing file", func(ctx context.Context) {
							targetFile := existingRemoteFile

							output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'k2s node copy' completed"))

							content := sshExec.mustExecEventually(ctx, "more "+targetFile)

							Expect(content).To(Equal(sourceFileContent))
						})

						When("target is file name only", func() {
							BeforeEach(func(ctx context.Context) {
								existingRemoteFile = sourceFileName

								GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

								sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
							})

							AfterEach(func(ctx context.Context) {
								GinkgoWriter.Println("Removing file <", existingRemoteFile, ">")

								sshExec.exec(ctx, "del "+existingRemoteFile)
							})

							It("overwrites existing file in home dir", func(ctx context.Context) {
								targetFile := sourceFileName

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content := sshExec.mustExecEventually(ctx, "more "+targetFile)

								Expect(content).To(Equal(sourceFileContent))
							})
						})
					})

					When("target is a folder", func() {
						When("file with same name exists in target", func() {
							var existingRemoteFile string

							BeforeEach(func(ctx context.Context) {
								existingRemoteFile = filepath.Join(remoteTempDir, sourceFileName)

								GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

								sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
							})

							It("overwrites the existing file", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content := sshExec.mustExecEventually(ctx, "more "+existingRemoteFile)

								Expect(content).To(Equal(sourceFileContent))
							})

							When("target is tilde (~\\) only", func() {
								BeforeEach(func(ctx context.Context) {
									existingRemoteFile = sourceFileName

									GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

									sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
								})

								AfterEach(func(ctx context.Context) {
									GinkgoWriter.Println("Removing file <", existingRemoteFile, ">")

									sshExec.exec(ctx, "del "+existingRemoteFile)
								})

								It("overwrites the existing file in the home dir", func(ctx context.Context) {
									targetFolder := "~\\"

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									content := sshExec.mustExecEventually(ctx, "more "+existingRemoteFile)

									Expect(content).To(Equal(sourceFileContent))
								})
							})
						})

						When("file with same name does not exist in target", func() {
							It("copies the file to target", func(ctx context.Context) {
								targetFolder := remoteTempDir
								expectedTargetFile := filepath.Join(remoteTempDir, sourceFileName)

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content := sshExec.mustExecEventually(ctx, "more "+expectedTargetFile)

								Expect(content).To(Equal(sourceFileContent))
							})

							When("target is tilde (~\\) only", func() {
								var expectedRemoteFile string

								BeforeEach(func() {
									expectedRemoteFile = sourceFileName
								})

								AfterEach(func(ctx context.Context) {
									GinkgoWriter.Println("Removing file <", expectedRemoteFile, ">")

									sshExec.exec(ctx, "del "+expectedRemoteFile)
								})

								It("copies the file to home dir", func(ctx context.Context) {
									targetFolder := "~\\"

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									content := sshExec.mustExecEventually(ctx, "more "+expectedRemoteFile)

									Expect(content).To(Equal(sourceFileContent))
								})
							})
						})
					})
				})

				When("target is not existing", func() {
					When("target parent folder is existing", func() {
						It("creates the target file and copies the content", func(ctx context.Context) {
							targetFile := filepath.Join(remoteTempDir, sourceFileName)

							output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'k2s node copy' completed"))

							content := sshExec.mustExecEventually(ctx, "more "+targetFile)

							Expect(content).To(Equal(sourceFileContent))
						})
					})

					When("target parent folder is not existing", func() {
						It("exits with failure", func(ctx context.Context) {
							targetFile := filepath.Join(remoteTempDir, "non-existent", sourceFileName)

							output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("parent .+ not existing"),
							))
						})
					})

					When("target is file name only", func() {
						var expectedRemoteFile string

						BeforeEach(func() {
							expectedRemoteFile = sourceFileName
						})

						AfterEach(func(ctx context.Context) {
							GinkgoWriter.Println("Removing file <", expectedRemoteFile, ">")

							sshExec.exec(ctx, "del "+expectedRemoteFile)
						})

						It("copies the file to home dir", func(ctx context.Context) {
							targetFile := sourceFileName

							output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'k2s node copy' completed"))

							content := sshExec.mustExecEventually(ctx, "more "+expectedRemoteFile)

							Expect(content).To(Equal(sourceFileContent))
						})
					})
				})
			})

			When("source is a folder", func() {
				const sourceFolderName = "test-folder"
				const sourceSubFolderName = "test-sub-folder"

				var sourceFileInfos = []struct {
					name      string
					subFolder string
					content   string
				}{
					{name: "test-1-file", subFolder: "", content: "test-content-1\r\n"},
					{name: "test-2-file", subFolder: sourceSubFolderName, content: "test-content-2\r\n"},
					{name: "test-3-file", subFolder: "", content: "test-content-3\r\n"},
				}

				var sourceFolder string

				BeforeEach(func(ctx context.Context) {
					sourceFolder = filepath.Join(localTempDir, sourceFolderName)

					GinkgoWriter.Println("Creating local source folder <", sourceFolder, ">")
					Expect(os.MkdirAll(sourceFolder, fs.ModePerm)).To(Succeed())

					for _, fileInfo := range sourceFileInfos {
						dir := sourceFolder

						if fileInfo.subFolder != "" {
							dir = filepath.Join(sourceFolder, fileInfo.subFolder)

							GinkgoWriter.Println("Creating local source sub folder <", dir, ">")
							Expect(os.MkdirAll(dir, fs.ModePerm)).To(Succeed())
						}

						filePath := filepath.Join(dir, fileInfo.name)

						GinkgoWriter.Println("Writing local source file <", filePath, ">")
						Expect(os.WriteFile(filePath, []byte(fileInfo.content), fs.ModePerm)).To(Succeed())
					}
				})

				When("target is existing", func() {
					When("target is a file", func() {
						var existingRemoteFile string

						BeforeEach(func(ctx context.Context) {
							existingRemoteFile = filepath.Join(remoteTempDir, "some-file")

							GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

							sshExec.mustExecEventually(ctx, "echo 'existing content' > "+existingRemoteFile)
						})

						It("exits with failure", func(ctx context.Context) {
							targetFile := existingRemoteFile

							output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("target .+ is a file"),
							))
						})
					})

					When("target is a folder", func() {
						When("source folder name exists in target", func() {
							var existingRemoteFolder string

							BeforeEach(func(ctx context.Context) {
								existingRemoteFolder = filepath.Join(remoteTempDir, sourceFolderName)

								GinkgoWriter.Println("Creating remote folder <", existingRemoteFolder, ">")

								sshExec.mustExecEventually(ctx, "mkdir "+existingRemoteFolder)
							})

							It("copies contents of source folder to existing folder in target dir", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								for _, fileInfo := range sourceFileInfos {
									remotePath := filepath.Join(existingRemoteFolder, fileInfo.subFolder, fileInfo.name)
									content := sshExec.mustExecEventually(ctx, "more "+remotePath)

									Expect(content).To(Equal(fileInfo.content))
								}
							})

							When("folder with same name contains files with same name", func() {
								BeforeEach(func(ctx context.Context) {
									for _, fileInfo := range sourceFileInfos {
										dir := existingRemoteFolder

										if fileInfo.subFolder != "" {
											dir = filepath.Join(dir, fileInfo.subFolder)

											GinkgoWriter.Println("Creating remote target sub folder <", dir, ">")
											sshExec.mustExecEventually(ctx, "mkdir "+dir)
										}

										filePath := filepath.Join(dir, fileInfo.name)

										GinkgoWriter.Println("Writing remote target file <", filePath, ">")
										sshExec.mustExecEventually(ctx, "echo 'existing content' > "+filePath)
									}
								})

								It("copies contents of source folder to existing folder in target dir, overwriting existing files", func(ctx context.Context) {
									targetFolder := remoteTempDir

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									for _, fileInfo := range sourceFileInfos {
										remotePath := filepath.Join(existingRemoteFolder, fileInfo.subFolder, fileInfo.name)
										content := sshExec.mustExecEventually(ctx, "more "+remotePath)

										Expect(content).To(Equal(fileInfo.content))
									}
								})
							})
						})

						When("source folder name does not exist in target", func() {
							It("copies the folder to target", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								for _, fileInfo := range sourceFileInfos {
									remotePath := filepath.Join(remoteTempDir, sourceFolderName, fileInfo.subFolder, fileInfo.name)
									content := sshExec.mustExecEventually(ctx, "more "+remotePath)

									Expect(content).To(Equal(fileInfo.content))
								}
							})
						})
					})
				})

				When("target is not existing", func() {
					When("target parent folder is existing", func() {
						It("creates target dir and copies contents of source folder", func(ctx context.Context) {
							targetFolder := filepath.Join(remoteTempDir, sourceFolderName)

							output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'k2s node copy' completed"))

							for _, fileInfo := range sourceFileInfos {
								remotePath := filepath.Join(targetFolder, fileInfo.subFolder, fileInfo.name)
								content := sshExec.mustExecEventually(ctx, "more "+remotePath)

								Expect(content).To(Equal(fileInfo.content))
							}
						})
					})

					When("target parent folder is not existing", func() {
						It("exits with failure", func(ctx context.Context) {
							targetFolder := filepath.Join(remoteTempDir, "non-existent-parent", sourceFolderName)

							output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("remote parent not existing"),
							))
						})
					})
				})
			})
		})
	})

	Describe("from node", func() {
		When("node is Linux node", Label("linux-node"), func() {
			const remoteUser = "remote"

			var nodeIpAddress string

			BeforeEach(func(ctx context.Context) {
				nodeIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

				GinkgoWriter.Println("Using control-plane node IP address <", nodeIpAddress, ">")
			})

			When("source does not exist", func() {
				DescribeTable("exits with failure", func(ctx context.Context, source string) {
					output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", source, "-t", "~\\", "-o", "-r", "-u", remoteUser)

					Expect(output).To(SatisfyAll(
						MatchRegexp("ERROR"),
						MatchRegexp("failed to copy"),
						MatchRegexp("source .+ does not exist"),
					))
				},
					Entry("file not existing", "~/non-existent.file"),
					Entry("folder not existing", "~/non-existent/folder/"),
				)
			})

			When("source exists", func() {
				var localTempDir string

				var remoteTempDirName string
				var remoteTempDir string

				var sshExec *sshExecutor

				BeforeEach(func(ctx context.Context) {
					localTempDir = GinkgoT().TempDir()
					remoteTempDirName = fmt.Sprintf("test_%d/", GinkgoRandomSeed())
					remoteTempDir = "~/" + remoteTempDirName

					sshExec = &sshExecutor{
						ipAddress:  nodeIpAddress,
						remoteUser: "remote",
						keyPath:    "~/.ssh\\k2s\\id_rsa",
						executor:   suite.Cli("ssh.exe"),
					}

					GinkgoWriter.Println("Creating remote temp dir <", remoteTempDir, ">")

					sshExec.mustExecEventually(ctx, "mkdir -p "+remoteTempDir)
				})

				AfterEach(func(ctx context.Context) {
					GinkgoWriter.Println("Removing remote temp dir <", remoteTempDir, ">")

					sshExec.exec(ctx, "rm -rf "+remoteTempDir)
				})

				When("source is a file", func() {
					const sourceFileName = "test.file"
					const sourceFileContent = "This is the test file content."

					var sourceFile string

					BeforeEach(func(ctx context.Context) {
						sourceFile = path.Join(remoteTempDir, sourceFileName)

						GinkgoWriter.Println("Creating remote file <", sourceFile, ">")
						sshExec.mustExecEventually(ctx, "echo -n '"+sourceFileContent+"' > "+sourceFile)
						GinkgoWriter.Println("Remote file <", sourceFile, "> created")
					})

					When("target is existing", func() {
						When("target is a file", func() {
							var existingLocalFile string

							BeforeEach(func(ctx context.Context) {
								existingLocalFile = filepath.Join(localTempDir, sourceFileName)

								GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
								Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
								GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
							})

							It("overwrites the existing file", func(ctx context.Context) {
								targetFile := existingLocalFile

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-r", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content, err := os.ReadFile(targetFile)

								Expect(err).ToNot(HaveOccurred())
								Expect(string(content)).To(Equal(sourceFileContent))
							})
						})

						When("target is a folder", func() {
							When("file with same name exists in target", func() {
								var existingLocalFile string

								BeforeEach(func(ctx context.Context) {
									existingLocalFile = filepath.Join(localTempDir, sourceFileName)

									GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
									Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
									GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
								})

								It("overwrites the existing file", func(ctx context.Context) {
									targetFolder := localTempDir

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									content, err := os.ReadFile(existingLocalFile)

									Expect(err).ToNot(HaveOccurred())
									Expect(string(content)).To(Equal(sourceFileContent))
								})

								When("target is tilde (~\\) only", func() {
									BeforeEach(func(ctx context.Context) {
										localHomeDir, err := os.UserHomeDir()
										Expect(err).ToNot(HaveOccurred())

										existingLocalFile = filepath.Join(localHomeDir, sourceFileName)

										GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
										Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
										GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
									})

									AfterEach(func(ctx context.Context) {
										GinkgoWriter.Println("Removing local file <", existingLocalFile, ">")
										Expect(os.Remove(existingLocalFile)).To(Succeed())
										GinkgoWriter.Println("Local file <", existingLocalFile, "> removed")
									})

									It("overwrites the existing file in the home dir", func(ctx context.Context) {
										targetFolder := "~\\"

										output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

										Expect(output).To(MatchRegexp("'k2s node copy' completed"))

										content, err := os.ReadFile(existingLocalFile)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(sourceFileContent))
									})
								})
							})

							When("file with same name does not exist in target", func() {
								It("copies the file to target", func(ctx context.Context) {
									targetFolder := localTempDir
									expectedTargetFile := filepath.Join(localTempDir, sourceFileName)

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									content, err := os.ReadFile(expectedTargetFile)

									Expect(err).ToNot(HaveOccurred())
									Expect(string(content)).To(Equal(sourceFileContent))
								})

								When("target is tilde (~\\) only", func() {
									var expectedTargetFile string

									BeforeEach(func() {
										localHomeDir, err := os.UserHomeDir()
										Expect(err).ToNot(HaveOccurred())

										expectedTargetFile = filepath.Join(localHomeDir, sourceFileName)
									})

									AfterEach(func(ctx context.Context) {
										GinkgoWriter.Println("Removing local file <", expectedTargetFile, ">")
										Expect(os.Remove(expectedTargetFile)).To(Succeed())
										GinkgoWriter.Println("Local file <", expectedTargetFile, "> removed")
									})

									It("copies the file to home dir", func(ctx context.Context) {
										targetFolder := "~\\"

										output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

										Expect(output).To(MatchRegexp("'k2s node copy' completed"))

										content, err := os.ReadFile(expectedTargetFile)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(sourceFileContent))
									})
								})
							})
						})
					})

					When("target is not existing", func() {
						When("target parent folder is existing", func() {
							It("creates the target file and copies the content", func(ctx context.Context) {
								targetFile := filepath.Join(localTempDir, sourceFileName)

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-r", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content, err := os.ReadFile(targetFile)

								Expect(err).ToNot(HaveOccurred())
								Expect(string(content)).To(Equal(sourceFileContent))
							})
						})

						When("target parent folder is not existing", func() {
							It("exits with failure", func(ctx context.Context) {
								targetFile := filepath.Join(localTempDir, "non-existent", sourceFileName)

								output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-r", "-u", remoteUser)

								Expect(output).To(SatisfyAll(
									MatchRegexp("ERROR"),
									MatchRegexp("failed to copy"),
									MatchRegexp("parent .+ not existing"),
								))
							})
						})
					})
				})

				When("source is a folder", func() {
					const sourceFolderName = "test-folder"
					const sourceSubFolderName = "test-sub-folder"

					var sourceFileInfos = []struct {
						name      string
						subFolder string
						content   string
					}{
						{name: "test-1-file", subFolder: "", content: "test-content-1"},
						{name: "test-2-file", subFolder: sourceSubFolderName, content: "test-content-2"},
						{name: "test-3-file", subFolder: "", content: "test-content-3"},
					}

					var sourceFolder string

					BeforeEach(func(ctx context.Context) {
						sourceFolder = path.Join(remoteTempDir, sourceFolderName)

						GinkgoWriter.Println("Creating remote source folder <", sourceFolder, ">")
						sshExec.mustExecEventually(ctx, "mkdir -p "+sourceFolder)

						for _, fileInfo := range sourceFileInfos {
							dir := sourceFolder

							if fileInfo.subFolder != "" {
								dir = path.Join(dir, fileInfo.subFolder)

								GinkgoWriter.Println("Creating remote source sub folder <", dir, ">")
								sshExec.mustExecEventually(ctx, "mkdir -p "+dir)
							}

							filePath := path.Join(dir, fileInfo.name)

							GinkgoWriter.Println("Writing remote source file <", filePath, ">")
							sshExec.mustExecEventually(ctx, "echo -n '"+fileInfo.content+"' > "+filePath)
						}
					})

					When("target is existing", func() {
						When("target is a file", func() {
							var existingLocalFile string

							BeforeEach(func(ctx context.Context) {
								existingLocalFile = filepath.Join(localTempDir, "some-file")

								GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
								Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
								GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
							})

							It("exits with failure", func(ctx context.Context) {
								targetFile := existingLocalFile

								output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFile, "-o", "-r", "-u", remoteUser)

								Expect(output).To(SatisfyAll(
									MatchRegexp("ERROR"),
									MatchRegexp("failed to copy"),
									MatchRegexp("target .+ is a file"),
								))
							})
						})

						When("target is a folder", func() {
							When("source folder name exists in target", func() {
								var existingLocalFolder string

								BeforeEach(func(ctx context.Context) {
									existingLocalFolder = filepath.Join(localTempDir, sourceFolderName)

									GinkgoWriter.Println("Creating local folder <", existingLocalFolder, ">")

									Expect(os.Mkdir(existingLocalFolder, fs.ModePerm)).To(Succeed())
								})

								It("copies contents of source folder to existing folder in target dir", func(ctx context.Context) {
									targetFolder := localTempDir

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									for _, fileInfo := range sourceFileInfos {
										localPath := filepath.Join(existingLocalFolder, fileInfo.subFolder, fileInfo.name)
										content, err := os.ReadFile(localPath)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(fileInfo.content))
									}
								})

								When("folder with same name contains files with same name", func() {
									BeforeEach(func(ctx context.Context) {
										for _, fileInfo := range sourceFileInfos {
											dir := existingLocalFolder

											if fileInfo.subFolder != "" {
												dir = filepath.Join(dir, fileInfo.subFolder)

												GinkgoWriter.Println("Creating local target sub folder <", dir, ">")
												Expect(os.MkdirAll(dir, fs.ModePerm)).To(Succeed())
											}

											filePath := filepath.Join(dir, fileInfo.name)

											GinkgoWriter.Println("Writing local target file <", filePath, ">")
											Expect(os.WriteFile(filePath, []byte("existing content"), fs.ModePerm)).To(Succeed())
										}
									})

									It("copies contents of source folder to existing folder in target dir, overwriting existing files", func(ctx context.Context) {
										targetFolder := localTempDir

										output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

										Expect(output).To(MatchRegexp("'k2s node copy' completed"))

										for _, fileInfo := range sourceFileInfos {
											localPath := filepath.Join(existingLocalFolder, fileInfo.subFolder, fileInfo.name)
											content, err := os.ReadFile(localPath)

											Expect(err).ToNot(HaveOccurred())
											Expect(string(content)).To(Equal(fileInfo.content))
										}
									})
								})
							})

							When("source folder name does not exist in target", func() {
								It("copies the folder to target", func(ctx context.Context) {
									targetFolder := localTempDir

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									for _, fileInfo := range sourceFileInfos {
										localPath := filepath.Join(localTempDir, sourceFolderName, fileInfo.subFolder, fileInfo.name)
										content, err := os.ReadFile(localPath)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(fileInfo.content))
									}
								})
							})
						})
					})

					When("target is not existing", func() {
						When("target parent folder is existing", func() {
							It("creates target dir and copies contents of source folder", func(ctx context.Context) {
								targetFolder := filepath.Join(localTempDir, sourceFolderName)

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								for _, fileInfo := range sourceFileInfos {
									localPath := filepath.Join(targetFolder, fileInfo.subFolder, fileInfo.name)
									content, err := os.ReadFile(localPath)

									Expect(err).ToNot(HaveOccurred())
									Expect(string(content)).To(Equal(fileInfo.content))
								}
							})
						})

						When("target parent folder is not existing", func() {
							It("exits with failure", func(ctx context.Context) {
								targetFolder := filepath.Join(localTempDir, "non-existent-parent", sourceFolderName)

								output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

								Expect(output).To(SatisfyAll(
									MatchRegexp("ERROR"),
									MatchRegexp("failed to copy"),
									MatchRegexp("local parent not existing"),
								))
							})
						})
					})
				})
			})
		})

		When("node is Windows node", Label("windows-node"), func() {
			const remoteUser = "administrator"

			var nodeIpAddress string

			BeforeEach(func(ctx context.Context) {
				if skipWinNodeTests {
					Skip("Windows node tests are skipped")
				}

				// TODO: set when adding Win nodes is supported
				nodeIpAddress = ""

				GinkgoWriter.Println("Using win worker node IP address <", nodeIpAddress, ">")
			})

			When("source does not exist", func() {
				DescribeTable("exits with failure", func(ctx context.Context, source string) {
					output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", source, "-t", "~\\", "-o", "-r", "-u", remoteUser)

					Expect(output).To(SatisfyAll(
						MatchRegexp("ERROR"),
						MatchRegexp("failed to copy"),
						MatchRegexp("source .+ does not exist"),
					))
				},
					Entry("file not existing", "~\\non-existent.file"),
					Entry("folder not existing", "~\\non-existent\\folder\\"),
				)
			})

			When("source exists", func() {
				var localTempDir string

				var remoteTempDirName string
				var remoteTempDir string

				var sshExec *sshExecutor

				BeforeEach(func(ctx context.Context) {
					localTempDir = GinkgoT().TempDir()
					remoteTempDirName = fmt.Sprintf("test_%d/", GinkgoRandomSeed())
					remoteTempDir = filepath.Join("C:\\Users", remoteUser, remoteTempDirName)

					sshExec = &sshExecutor{
						ipAddress:  nodeIpAddress,
						remoteUser: remoteUser,
						keyPath:    "~/.ssh\\k2s\\id_rsa",
						executor:   suite.Cli("ssh.exe"),
					}

					GinkgoWriter.Println("Creating remote temp dir <", remoteTempDir, ">")

					sshExec.mustExecEventually(ctx, "mkdir "+remoteTempDir)
				})

				AfterEach(func(ctx context.Context) {
					GinkgoWriter.Println("Removing remote temp dir <", remoteTempDir, ">")

					sshExec.exec(ctx, "rd /s /q "+remoteTempDir)
				})

				When("source is a file", func() {
					const sourceFileName = "test.file"
					const sourceFileContent = "This is the test file content."

					var sourceFile string

					BeforeEach(func(ctx context.Context) {
						sourceFile = filepath.Join(remoteTempDir, sourceFileName)

						GinkgoWriter.Println("Creating remote file <", sourceFile, ">")
						sshExec.mustExecEventually(ctx, "echo | set /p tempVar=\""+sourceFileContent+"\" > "+sourceFile)
						GinkgoWriter.Println("Remote file <", sourceFile, "> created")
					})

					When("target is existing", func() {
						When("target is a file", func() {
							var existingLocalFile string

							BeforeEach(func(ctx context.Context) {
								existingLocalFile = filepath.Join(localTempDir, sourceFileName)

								GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
								Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
								GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
							})

							It("overwrites the existing file", func(ctx context.Context) {
								targetFile := existingLocalFile

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser, "-r")

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content, err := os.ReadFile(targetFile)

								Expect(err).ToNot(HaveOccurred())
								Expect(string(content)).To(Equal(sourceFileContent))
							})
						})

						When("target is a folder", func() {
							When("file with same name exists in target", func() {
								var existingLocalFile string

								BeforeEach(func(ctx context.Context) {
									existingLocalFile = filepath.Join(localTempDir, sourceFileName)

									GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
									Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
									GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
								})

								It("overwrites the existing file", func(ctx context.Context) {
									targetFolder := localTempDir

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser, "-r")

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									content, err := os.ReadFile(existingLocalFile)

									Expect(err).ToNot(HaveOccurred())
									Expect(string(content)).To(Equal(sourceFileContent))
								})

								When("target is tilde (~\\) only", func() {
									BeforeEach(func(ctx context.Context) {
										localHomeDir, err := os.UserHomeDir()
										Expect(err).ToNot(HaveOccurred())

										existingLocalFile = filepath.Join(localHomeDir, sourceFileName)

										GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
										Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
										GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
									})

									AfterEach(func(ctx context.Context) {
										GinkgoWriter.Println("Removing local file <", existingLocalFile, ">")
										Expect(os.Remove(existingLocalFile)).To(Succeed())
										GinkgoWriter.Println("Local file <", existingLocalFile, "> removed")
									})

									It("overwrites the existing file in the home dir", func(ctx context.Context) {
										targetFolder := "~\\"

										output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser, "-r")

										Expect(output).To(MatchRegexp("'k2s node copy' completed"))

										content, err := os.ReadFile(existingLocalFile)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(sourceFileContent))
									})
								})
							})

							When("file with same name does not exist in target", func() {
								It("copies the file to target", func(ctx context.Context) {
									targetFolder := localTempDir
									expectedTargetFile := filepath.Join(localTempDir, sourceFileName)

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser, "-r")

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									content, err := os.ReadFile(expectedTargetFile)

									Expect(err).ToNot(HaveOccurred())
									Expect(string(content)).To(Equal(sourceFileContent))
								})

								When("target is tilde (~\\) only", func() {
									var expectedLocalFile string

									BeforeEach(func() {
										localHomeDir, err := os.UserHomeDir()
										Expect(err).ToNot(HaveOccurred())

										expectedLocalFile = filepath.Join(localHomeDir, sourceFileName)
									})

									AfterEach(func(ctx context.Context) {
										GinkgoWriter.Println("Removing local file <", expectedLocalFile, ">")
										Expect(os.Remove(expectedLocalFile)).To(Succeed())
										GinkgoWriter.Println("Local file <", expectedLocalFile, "> removed")
									})

									It("copies the file to home dir", func(ctx context.Context) {
										targetFolder := "~\\"

										output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser, "-r")

										Expect(output).To(MatchRegexp("'k2s node copy' completed"))

										content, err := os.ReadFile(expectedLocalFile)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(sourceFileContent))
									})
								})
							})
						})
					})

					When("target is not existing", func() {
						When("target parent folder is existing", func() {
							It("creates the target file and copies the content", func(ctx context.Context) {
								targetFile := filepath.Join(localTempDir, sourceFileName)

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser, "-r")

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								content, err := os.ReadFile(targetFile)

								Expect(err).ToNot(HaveOccurred())
								Expect(string(content)).To(Equal(sourceFileContent))
							})
						})

						When("target parent folder is not existing", func() {
							It("exits with failure", func(ctx context.Context) {
								targetFile := filepath.Join(localTempDir, "non-existent", sourceFileName)

								output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser, "-r")

								Expect(output).To(SatisfyAll(
									MatchRegexp("ERROR"),
									MatchRegexp("failed to copy"),
									MatchRegexp("parent .+ not existing"),
								))
							})
						})
					})
				})

				When("source is a folder", func() {
					const sourceFolderName = "test-folder"
					const sourceSubFolderName = "test-sub-folder"

					var sourceFileInfos = []struct {
						name      string
						subFolder string
						content   string
					}{
						{name: "test-1-file", subFolder: "", content: "test-content-1"},
						{name: "test-2-file", subFolder: sourceSubFolderName, content: "test-content-2"},
						{name: "test-3-file", subFolder: "", content: "test-content-3"},
					}

					var sourceFolder string

					BeforeEach(func(ctx context.Context) {
						sourceFolder = filepath.Join(remoteTempDir, sourceFolderName)

						GinkgoWriter.Println("Creating remote source folder <", sourceFolder, ">")
						sshExec.mustExecEventually(ctx, "mkdir "+sourceFolder)

						for _, fileInfo := range sourceFileInfos {
							dir := sourceFolder

							if fileInfo.subFolder != "" {
								dir = filepath.Join(dir, fileInfo.subFolder)

								GinkgoWriter.Println("Creating remote source sub folder <", dir, ">")
								sshExec.mustExecEventually(ctx, "mkdir "+dir)
							}

							filePath := filepath.Join(dir, fileInfo.name)

							GinkgoWriter.Println("Writing remote source file <", filePath, ">")
							sshExec.mustExecEventually(ctx, "echo | set /p tempVar=\""+fileInfo.content+"\" > "+filePath)
						}
					})

					When("target is existing", func() {
						When("target is a file", func() {
							var existingLocalFile string

							BeforeEach(func(ctx context.Context) {
								existingLocalFile = filepath.Join(localTempDir, "some-file")

								GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
								Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
								GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
							})

							It("exits with failure", func(ctx context.Context) {
								targetFile := existingLocalFile

								output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFile, "-o", "-u", remoteUser, "-r")

								Expect(output).To(SatisfyAll(
									MatchRegexp("ERROR"),
									MatchRegexp("failed to copy"),
									MatchRegexp("target .+ is a file"),
								))
							})
						})

						When("target is a folder", func() {
							When("source folder name exists in target", func() {
								var existingLocalFolder string

								BeforeEach(func(ctx context.Context) {
									existingLocalFolder = filepath.Join(localTempDir, sourceFolderName)

									GinkgoWriter.Println("Creating local folder <", existingLocalFolder, ">")
									Expect(os.MkdirAll(existingLocalFolder, fs.ModePerm)).To(Succeed())
									GinkgoWriter.Println("Local folder <", existingLocalFolder, "> created")
								})

								It("copies contents of source folder to existing folder in target dir", func(ctx context.Context) {
									targetFolder := localTempDir

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser, "-r")

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									for _, fileInfo := range sourceFileInfos {
										localPath := filepath.Join(existingLocalFolder, fileInfo.subFolder, fileInfo.name)
										content, err := os.ReadFile(localPath)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(fileInfo.content))
									}
								})

								When("folder with same name contains files with same name", func() {
									BeforeEach(func(ctx context.Context) {
										for _, fileInfo := range sourceFileInfos {
											dir := existingLocalFolder

											if fileInfo.subFolder != "" {
												dir = filepath.Join(dir, fileInfo.subFolder)

												GinkgoWriter.Println("Creating local target sub folder <", dir, ">")
												Expect(os.MkdirAll(dir, fs.ModePerm)).To(Succeed())
											}

											filePath := filepath.Join(dir, fileInfo.name)

											GinkgoWriter.Println("Writing local target file <", filePath, ">")
											Expect(os.WriteFile(filePath, []byte("existing content"), fs.ModePerm)).To(Succeed())
										}
									})

									It("copies contents of source folder to existing folder in target dir, overwriting existing files", func(ctx context.Context) {
										targetFolder := localTempDir

										output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser, "-r")

										Expect(output).To(MatchRegexp("'k2s node copy' completed"))

										for _, fileInfo := range sourceFileInfos {
											localPath := filepath.Join(existingLocalFolder, fileInfo.subFolder, fileInfo.name)
											content, err := os.ReadFile(localPath)

											Expect(err).ToNot(HaveOccurred())
											Expect(string(content)).To(Equal(fileInfo.content))
										}
									})
								})
							})

							When("source folder name does not exist in target", func() {
								It("copies the folder to target", func(ctx context.Context) {
									targetFolder := localTempDir

									output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser, "-r")

									Expect(output).To(MatchRegexp("'k2s node copy' completed"))

									for _, fileInfo := range sourceFileInfos {
										localPath := filepath.Join(localTempDir, sourceFolderName, fileInfo.subFolder, fileInfo.name)
										content, err := os.ReadFile(localPath)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(fileInfo.content))
									}
								})
							})
						})
					})

					When("target is not existing", func() {
						When("target parent folder is existing", func() {
							It("creates target dir and copies contents of source folder", func(ctx context.Context) {
								targetFolder := filepath.Join(localTempDir, sourceFolderName)

								output := suite.K2sCli().MustExec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser, "-r")

								Expect(output).To(MatchRegexp("'k2s node copy' completed"))

								for _, fileInfo := range sourceFileInfos {
									localPath := filepath.Join(targetFolder, fileInfo.subFolder, fileInfo.name)
									content, err := os.ReadFile(localPath)

									Expect(err).ToNot(HaveOccurred())
									Expect(string(content)).To(Equal(fileInfo.content))
								}
							})
						})

						When("target parent folder is not existing", func() {
							It("exits with failure", func(ctx context.Context) {
								targetFolder := filepath.Join(localTempDir, "non-existent-parent", sourceFolderName)

								output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser, "-r")

								Expect(output).To(SatisfyAll(
									MatchRegexp("ERROR"),
									MatchRegexp("failed to copy"),
									MatchRegexp("local parent not existing"),
								))
							})
						})
					})
				})
			})
		})
	})
})

// isTransientSSHExitCode returns true for exit codes that indicate
// transient SSH failures which should be retried.
func isTransientSSHExitCode(exitCode int) bool {
	switch exitCode {
	case int(cli.ExitCodeSuccess):
		return true // Success - let Eventually check complete
	case -1:
		return true // Process interrupted/not complete
	case 255:
		return true // SSH connection error
	case 3221226356: // Windows STATUS_PENDING (0xC0000174)
		return true // "close - IO is still pending on closed socket"
	case 3221225477: // Windows STATUS_ACCESS_VIOLATION (0xC0000005)
		return true // Transient access violation during SSH
	default:
		return false
	}
}

// isTransientSSHOutput returns true if the output contains transient SSH error messages
// that should trigger a retry regardless of exit code.
func isTransientSSHOutput(output string) bool {
	return strings.Contains(output, "IO is still pending") ||
		strings.Contains(output, "Connection reset by peer") ||
		strings.Contains(output, "Connection closed by remote host")
}

func (ssh sshExecutor) mustExecEventually(ctx context.Context, remoteCmd string) string {
	var output string

	Eventually(func(ctx context.Context) int {
		var exitCode int
		output, exitCode = ssh.executor.Exec(ctx, "-n", "-o", "StrictHostKeyChecking=no", "-i", ssh.keyPath, ssh.remoteUser+"@"+ssh.ipAddress, remoteCmd)

		// Check for transient SSH errors in output (regardless of exit code)
		if isTransientSSHOutput(output) {
			GinkgoWriter.Printf("SSH command encountered transient error in output, will retry...\n")
			return -1 // Force retry by returning a transient exit code
		}

		if !isTransientSSHExitCode(exitCode) {
			Fail(fmt.Sprintf("SSH command failed with non-transient exit code %d, output: %s", exitCode, output))
		}

		if exitCode != int(cli.ExitCodeSuccess) {
			GinkgoWriter.Printf("SSH command returned transient exit code %d, will retry...\n", exitCode)
		}

		return exitCode
	}).WithContext(ctx).WithTimeout(time.Minute).WithPolling(2 * time.Second).Should(BeEquivalentTo(cli.ExitCodeSuccess))

	return output
}

func (ssh sshExecutor) exec(ctx context.Context, remoteCmd string) {
	ssh.executor.Exec(ctx, "-n", "-o", "StrictHostKeyChecking=no", "-i", ssh.keyPath, ssh.remoteUser+"@"+ssh.ipAddress, remoteCmd)
}
