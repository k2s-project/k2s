// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package os_test

import (
	"context"
	"io/fs"
	"log/slog"
	bos "os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/os"
	"github.com/k2s-project/k2s/internal/test/reflection"
	"github.com/stretchr/testify/mock"
)

type stdWriterMock struct {
	mock.Mock
}

type fileInfoMock struct {
	mock.Mock
}

func (m *stdWriterMock) WriteStdOut(message string) {
	m.Called(message)
}

func (m *stdWriterMock) WriteStdErr(message string) {
	m.Called(message)
}

func (m *stdWriterMock) Flush() {
	m.Called()
}

func (m *fileInfoMock) Name() string {
	return m.Called().String(0)
}

func (m *fileInfoMock) Size() int64 {
	return int64(m.Called().Int(0))
}

func (m *fileInfoMock) Mode() fs.FileMode {
	return m.Called().Get(0).(fs.FileMode)
}

func (m *fileInfoMock) ModTime() time.Time {
	return m.Called().Get(0).(time.Time)
}

func (m *fileInfoMock) IsDir() bool {
	return m.Called().Bool(0)
}

func (m *fileInfoMock) Sys() any {
	return m.Called().Get(0)
}

func TestOsPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "os pkg Integration Tests", Label("ci", "internal", "os"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("os pkg", Ordered, func() {
	Describe("ExecutableDir", Label("integration"), func() {
		It("returns an existing directory", func() {
			dir, err := os.ExecutableDir()

			Expect(err).ToNot(HaveOccurred())

			GinkgoWriter.Println("Executable dir:", dir)

			info, err := bos.Stat(dir)
			Expect(err).ToNot(HaveOccurred())
			Expect(info.IsDir()).To(BeTrue())
		})
	})

	Describe("PathExists", Label("integration"), func() {
		When("path exists", func() {
			It("returns true", func() {
				input, err := bos.Executable()
				Expect(err).ToNot(HaveOccurred())

				result := os.PathExists(input)

				Expect(result).To(BeTrue())
			})
		})

		When("path does not exist", func() {
			It("returns false", func() {
				input := filepath.Join(GinkgoT().TempDir(), "non-existent")

				result := os.PathExists(input)

				Expect(result).To(BeFalse())
			})
		})
	})

	Describe("RemovePaths", Label("integration"), func() {
		When("no paths passed", func() {
			It("does nothing", func() {
				Expect(os.RemovePaths()).To(Succeed())
			})
		})

		When("non-existent path passed", func() {
			It("returns error", func() {
				Expect(os.RemovePaths("non-existent")).ToNot(Succeed())
			})
		})

		When("paths exist", func() {
			var filePath string
			var dirPath string

			BeforeEach(func() {
				temp := GinkgoT().TempDir()
				dirPath = filepath.Join(temp, "test-dir")
				filePath = filepath.Join(temp, "test.file")

				Expect(bos.MkdirAll(dirPath, bos.ModePerm)).To(Succeed())
				Expect(bos.WriteFile(filePath, []byte("test-content"), bos.ModePerm)).To(Succeed())
			})

			It("deletes files and directories", func() {
				Expect(os.RemovePaths(filePath, dirPath)).To(Succeed())
			})
		})
	})

	Describe("AppendToFile", Label("integration"), func() {
		When("non-existent path passed", func() {
			It("returns error", func() {
				Expect(os.AppendToFile("non-existent", "")).ToNot(Succeed())
			})
		})

		When("path exists", func() {
			var path string

			BeforeEach(func() {
				path = filepath.Join(GinkgoT().TempDir(), "test.file")

				Expect(bos.WriteFile(path, []byte("first-entry"), bos.ModePerm)).To(Succeed())
			})

			It("appends to file", func() {
				const textToAppend = "last-entry"

				err := os.AppendToFile(path, textToAppend)

				Expect(err).ToNot(HaveOccurred())

				content, err := bos.ReadFile(path)
				Expect(err).ToNot(HaveOccurred())

				Expect(strings.HasSuffix(string(content), textToAppend)).To(BeTrue())
			})
		})
	})

	Describe("CopyFile", Label("integration"), func() {
		When("source file non-existent", func() {
			It("returns error", func() {
				const source = "non-existent"
				const target = ""

				err := os.CopyFile(source, target)

				Expect(err).To(MatchError(ContainSubstring("could not read file")))
			})
		})

		When("target dir non-existent", func() {
			var source string
			var target string

			BeforeEach(func() {
				temp := GinkgoT().TempDir()
				source = filepath.Join(temp, "test.file")
				target = temp

				Expect(bos.WriteFile(source, []byte("test-content"), bos.ModePerm)).To(Succeed())
			})

			It("returns error", func() {
				err := os.CopyFile(source, target)

				Expect(err).To(MatchError(ContainSubstring("could not write file")))
			})
		})

		When("successful", func() {
			var source string
			var target string

			BeforeEach(func() {
				temp := GinkgoT().TempDir()
				source = filepath.Join(temp, "test.file")
				target = filepath.Join(temp, "copy.file")

				Expect(bos.WriteFile(source, []byte("test-content"), bos.ModePerm)).To(Succeed())
			})

			It("copies the file", func() {
				Expect(os.CopyFile(source, target)).To(Succeed())

				content, err := bos.ReadFile(target)
				Expect(err).ToNot(HaveOccurred())
				Expect(string(content)).To(Equal("test-content"))
			})
		})
	})

	Describe("FilesInDir", Label("integration"), func() {
		When("error occurs during reading dir", func() {
			It("returns error", func() {
				actual, err := os.FilesInDir("non-existent")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("could not read directory")))
			})
		})

		When("dir only contains sub-dirs", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()

				Expect(bos.MkdirAll(filepath.Join(dir, "sub-dir-1"), bos.ModePerm)).To(Succeed())
				Expect(bos.MkdirAll(filepath.Join(dir, "sub-dir-2"), bos.ModePerm)).To(Succeed())
			})

			It("returns empty list", func() {
				actual, err := os.FilesInDir(dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeEmpty())
			})
		})

		When("dir tree contains files and sub-dirs with files", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				subDir1 := filepath.Join(dir, "sub-dir-1")
				subDir2 := filepath.Join(dir, "sub-dir-2")

				Expect(bos.MkdirAll(subDir1, bos.ModePerm)).To(Succeed())
				Expect(bos.MkdirAll(subDir2, bos.ModePerm)).To(Succeed())

				filePath1 := filepath.Join(dir, "file-1")
				filePath2 := filepath.Join(dir, "file-2")
				filePath3 := filepath.Join(subDir1, "file-3")
				filePath4 := filepath.Join(subDir2, "file-4")

				Expect(bos.WriteFile(filePath1, []byte(""), bos.ModePerm)).To(Succeed())
				Expect(bos.WriteFile(filePath2, []byte(""), bos.ModePerm)).To(Succeed())
				Expect(bos.WriteFile(filePath3, []byte(""), bos.ModePerm)).To(Succeed())
				Expect(bos.WriteFile(filePath4, []byte(""), bos.ModePerm)).To(Succeed())

				GinkgoWriter.Println("Test files written:", filePath1, filePath2, filePath3, filePath4)
			})

			It("returns only files being direct children of dir", func() {
				actual, err := os.FilesInDir(dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(ConsistOf(
					HaveField("Name()", "file-1"),
					HaveField("Name()", "file-2"),
				))
			})
		})
	})

	Describe("Exec", Label("integration"), func() {
		When("command cannot be started", func() {
			It("returns error", func(ctx context.Context) {
				sut := os.NewCmd("this-should-fail").WithContext(ctx)

				err := sut.Exec()

				Expect(err).To(MatchError(ContainSubstring("failed to start command")))
			})
		})

		When("command outputs text over stderr", func() {
			It("calls stderr writer", func(ctx context.Context) {
				const (
					scriptLoC     = 4
					resultLines   = 1
					errorLines    = 3
					linesPerError = scriptLoC + resultLines + errorLines
					script        = `
						for ($i = 0; $i -lt 5; $i++) {
							Write-Error "$i"
						}
						exit 0
						`
				)

				lineCounter := 0
				numberCounter := 0

				stdErrWriter := func(msg string, args ...any) {
					if (lineCounter+scriptLoC)%linesPerError == 0 {
						Expect(msg).To(MatchRegexp(".*: %d", numberCounter))

						numberCounter++
					}
					lineCounter++
				}

				sut := os.NewCmd("powershell").WithArgs(script).WithContext(ctx).WithStdErrWriter(stdErrWriter)

				err := sut.Exec()

				Expect(err).ToNot(HaveOccurred())
				Expect(lineCounter).To(Equal(5 * linesPerError))
			})
		})

		When("command outputs text over stdout", func() {
			It("calls stdout writer", func(ctx context.Context) {
				const script = `
						for ($i = 0; $i -lt 5; $i++) {
							Write-Output "$i"
						}
						`
				lineCounter := 0

				stdOutWriter := func(msg string, args ...any) {
					number, err := strconv.Atoi(msg)

					Expect(err).ToNot(HaveOccurred())

					Expect(number).To(Equal(lineCounter))

					lineCounter++
				}

				sut := os.NewCmd("powershell").WithArgs(script).WithContext(ctx).WithStdOutWriter(stdOutWriter)

				err := sut.Exec()

				Expect(err).ToNot(HaveOccurred())
				Expect(lineCounter).To(Equal(5))
			})
		})

		When("command exits with non-zero exit code", func() {
			It("returns error with exit status text", func(ctx context.Context) {
				sut := os.NewCmd("powershell").WithArgs("exit 123").WithContext(ctx)

				err := sut.Exec()

				Expect(err).To(MatchError(SatisfyAll(
					ContainSubstring("command 'powershell' failed"),
					ContainSubstring("exit status 123"),
				)))
			})
		})
	})

	Describe("ExecuteCmd", Label("integration"), func() {
		When("command cannot be started", func() {
			It("returns error", func(ctx context.Context) {
				writerMock := &stdWriterMock{}

				sut := os.NewCmdExecutor(writerMock).WithContext(ctx)

				err := sut.ExecuteCmd("this-should-fail")

				Expect(err).To(MatchError(ContainSubstring("command could not be started")))
			})
		})

		When("command outputs text over stderr", func() {
			It("calls stderr writer", func(ctx context.Context) {
				const (
					scriptLoC     = 4
					resultLines   = 1
					errorLines    = 3
					linesPerError = scriptLoC + resultLines + errorLines
					script        = `
						for ($i = 0; $i -lt 5; $i++) {
							Write-Error "$i"
						}
						exit 0
						`
				)

				lineCounter := 0
				numberCounter := 0

				writerMock := &stdWriterMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.WriteStdErr), mock.MatchedBy(func(line string) bool {
					expectationFulfilled := true

					if (lineCounter+scriptLoC)%linesPerError == 0 {
						expectationFulfilled = Expect(line).To(MatchRegexp(".*: %d", numberCounter))

						numberCounter++
					}

					lineCounter++

					return expectationFulfilled
				})).Times(5 * linesPerError)
				writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

				sut := os.NewCmdExecutor(writerMock).WithContext(ctx)

				err := sut.ExecuteCmd("powershell", script)

				Expect(err).ToNot(HaveOccurred())

				writerMock.AssertExpectations(GinkgoT())
			})
		})

		When("command outputs text over stdout", func() {
			It("calls stdout writer", func(ctx context.Context) {
				const script = `
						for ($i = 0; $i -lt 5; $i++) {
							Write-Output "$i"
						}
						`
				lineCounter := 0

				writerMock := &stdWriterMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.WriteStdOut), mock.MatchedBy(func(line string) bool {
					number, err := strconv.Atoi(line)

					Expect(err).ToNot(HaveOccurred())

					expectationFulfilled := number == lineCounter

					lineCounter++

					return expectationFulfilled
				})).Times(5)
				writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

				sut := os.NewCmdExecutor(writerMock).WithContext(ctx)

				err := sut.ExecuteCmd("powershell", script)

				Expect(err).ToNot(HaveOccurred())

				writerMock.AssertExpectations(GinkgoT())
			})
		})

		When("command exits with non-zero exit code", func() {
			It("returns error with exit status text", func(ctx context.Context) {
				const script = "exit 123"

				writerMock := &stdWriterMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

				sut := os.NewCmdExecutor(writerMock).WithContext(ctx)

				err := sut.ExecuteCmd("powershell", script)

				Expect(err).To(MatchError(SatisfyAll(
					ContainSubstring("command failed"),
					ContainSubstring("exit status 123"),
				)))

				writerMock.AssertExpectations(GinkgoT())
			})
		})
	})

	Describe("Files", Label("unit"), func() {
		Describe("OlderThan", func() {
			When("no files are older", func() {
				It("returns empty list", func() {
					now := time.Now()
					maxAge := time.Hour

					fileMock := &fileInfoMock{}
					fileMock.On(reflection.GetFunctionName(fileMock.ModTime)).Return(now)

					files := os.Files{
						fileMock,
					}

					actual := files.OlderThan(maxAge)

					Expect(actual).To(BeEmpty())
				})
			})

			When("files are older than the given duration", func() {
				It("returns older files", func() {
					now := time.Now()
					maxAge := time.Hour

					oldFileMock := &fileInfoMock{}
					oldFileMock.On(reflection.GetFunctionName(oldFileMock.ModTime)).Return(now.Add(-2 * maxAge))

					newFileMock := &fileInfoMock{}
					newFileMock.On(reflection.GetFunctionName(newFileMock.ModTime)).Return(now)

					files := os.Files{
						oldFileMock,
						newFileMock,
					}

					actual := files.OlderThan(maxAge)

					Expect(actual).To(ConsistOf(oldFileMock))
				})
			})

		})

		Describe("JoinPathsWith", func() {
			When("list is empty", func() {
				It("returns empty list", func() {
					path := ""
					files := os.Files{}

					actual := files.JoinPathsWith(path)

					Expect(actual).To(BeEmpty())
				})
			})

			When("list contains files", func() {
				It("returns list of joint file paths", func() {
					path := "parent-dir"
					fileMock1 := &fileInfoMock{}
					fileMock1.On(reflection.GetFunctionName(fileMock1.Name)).Return("file-1")

					fileMock2 := &fileInfoMock{}
					fileMock2.On(reflection.GetFunctionName(fileMock2.Name)).Return("file-2")

					files := os.Files{
						fileMock1,
						fileMock2,
					}

					actual := files.JoinPathsWith(path)

					Expect(actual).To(ConsistOf(
						"parent-dir\\file-1",
						"parent-dir\\file-2",
					))
				})
			})
		})
	})

	Describe("Paths", Label("integration"), func() {
		Describe("Remove", func() {
			var dir string
			paths := make(os.Paths, 2)

			BeforeEach(func() {
				dir = GinkgoT().TempDir()

				paths[0] = filepath.Join(dir, "file-1")
				paths[1] = filepath.Join(dir, "file-2")

				Expect(bos.WriteFile(paths[0], []byte(""), bos.ModePerm)).To(Succeed())
				Expect(bos.WriteFile(paths[1], []byte(""), bos.ModePerm)).To(Succeed())

				GinkgoWriter.Println("Test files written:", paths)
			})

			It("removes the paths", func() {
				err := paths.Remove()

				Expect(err).ToNot(HaveOccurred())

				for _, path := range paths {
					_, err := bos.Stat(path)
					Expect(err).To(MatchError(fs.ErrNotExist))
				}
			})
		})
	})
})
