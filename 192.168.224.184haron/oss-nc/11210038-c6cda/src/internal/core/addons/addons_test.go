// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package addons

import (
	"errors"
	"log/slog"
	"path/filepath"
	"testing"

	r "github.com/k2s-project/k2s/internal/test/reflection"

	"io/fs"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) Name() string {
	args := m.Called()

	return args.String(0)
}

func (m *mockObject) IsDir() bool {
	args := m.Called()

	return args.Bool(0)
}

func (m *mockObject) Type() fs.FileMode {
	args := m.Called()

	return args.Get(0).(fs.FileMode)
}

func (m *mockObject) Info() (fs.FileInfo, error) {
	args := m.Called()

	return args.Get(0).(fs.FileInfo), args.Error(1)
}

func (m *mockObject) walkDir(root string, fn fs.WalkDirFunc) error {
	args := m.Called(root, fn)

	return args.Error(0)
}

func (m *mockObject) readFile(p string) ([]byte, error) {
	args := m.Called(p)

	return args.Get(0).([]byte), args.Error(1)
}

func (m *mockObject) unmarshal(data []byte, v any) error {
	args := m.Called(data, v)

	return args.Error(0)
}

func (m *mockObject) validateAgainstSchema(v any) error {
	args := m.Called(v)

	return args.Error(0)
}

func (m *mockObject) validateContent(addon Addon) error {
	args := m.Called(addon)

	return args.Error(0)
}

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons Unit Tests", Label("unit", "ci", "addons"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("addons", func() {
	Describe("FullDescription", func() {
		When("error occurred", func() {
			It("returns error", func() {
				input := CliFlag{
					Constraints: &Constraints{Kind: "invalid"},
				}

				result, err := input.FullDescription()

				Expect(err).To(HaveOccurred())
				Expect(result).To(BeEmpty())
			})
		})

		When("neither description nor constraints exist", func() {
			It("returns empty string", func() {
				input := CliFlag{}

				result, err := input.FullDescription()

				Expect(err).ToNot(HaveOccurred())
				Expect(result).To(BeEmpty())
			})
		})

		When("only description exists", func() {
			It("returns description only", func() {
				input := CliFlag{Description: new("test")}

				result, err := input.FullDescription()

				Expect(err).ToNot(HaveOccurred())
				Expect(result).To(Equal("test"))
			})
		})

		When("only constraints exists", func() {
			It("returns constraints text only", func() {
				input := CliFlag{Constraints: &Constraints{
					Kind:          ValidationSetConstraintsType,
					ValidationSet: &ValidationSet{"v1", "v2"}}}

				result, err := input.FullDescription()

				Expect(err).ToNot(HaveOccurred())
				Expect(result).To(Equal("[v1|v2]"))
			})
		})

		When("both description and constraints exist", func() {
			It("returns text with description and constraints", func() {
				input := CliFlag{
					Description: new("test"),
					Constraints: &Constraints{
						Kind:          ValidationSetConstraintsType,
						ValidationSet: &ValidationSet{"v1", "v2"}}}

				result, err := input.FullDescription()

				Expect(err).ToNot(HaveOccurred())
				Expect(result).To(Equal("test [v1|v2]"))
			})
		})
	})

	Describe("CliExamples - String", func() {
		When("examples slice is empty", func() {
			It("returns empty string", func() {
				input := CliExamples{}

				result := input.String()

				Expect(result).To(BeEmpty())
			})
		})

		When("only one example exists", func() {
			It("returns example string without separating newline", func() {
				input := CliExamples{CliExample{Cmd: "test-cmd"}}

				result := input.String()

				Expect(result).To(Equal("  test-cmd\n"))
			})
		})

		When("multiple examples exist", func() {
			It("returns examples string with separating newlines", func() {
				input := CliExamples{
					CliExample{Cmd: "c1"},
					CliExample{Cmd: "c2"},
					CliExample{Cmd: "c3"}}

				result := input.String()

				Expect(result).To(Equal("  c1\n\n  c2\n\n  c3\n"))
			})
		})
	})

	Describe("CliExample - String", func() {
		When("no comment exists", func() {
			It("returns the command only", func() {
				input := CliExample{Cmd: "c1"}

				result := input.String()

				Expect(result).To(Equal("  c1\n"))
			})
		})

		When("comment exists", func() {
			It("returns comment and command", func() {
				input := CliExample{Cmd: "c1", Comment: new("test-comment")}

				result := input.String()

				Expect(result).To(Equal("  // test-comment\n  c1\n"))
			})
		})
	})

	Describe("Constraints", func() {
		Describe("String", func() {
			When("constraints are nil", func() {
				It("returns empty string", func() {
					var input *Constraints

					result, err := input.String()

					Expect(err).ToNot(HaveOccurred())
					Expect(result).To(BeEmpty())
				})
			})

			When("kind is invalid", func() {
				It("returns error", func() {
					input := &Constraints{Kind: "invalid"}

					result, err := input.String()

					Expect(err).To(MatchError(ContainSubstring("unknown constraint")))
					Expect(result).To(BeEmpty())
				})
			})

			When("kind is validation set", func() {
				It("returns validation set as string", func() {
					input := &Constraints{
						Kind:          ValidationSetConstraintsType,
						ValidationSet: &ValidationSet{"v1", "v2"}}

					result, err := input.String()

					Expect(err).ToNot(HaveOccurred())
					Expect(result).To(Equal("[v1|v2]"))
				})
			})

			When("kind is range", func() {
				It("returns range as string", func() {
					input := &Constraints{
						Kind:        RangeConstraintsType,
						NumberRange: &Range{Min: 1, Max: 9}}

					result, err := input.String()

					Expect(err).ToNot(HaveOccurred())
					Expect(result).To(Equal("[1,9]"))
				})
			})
		})

		Describe("Validate", func() {
			When("constraints are nil", func() {
				It("returns nil", func() {
					var input *Constraints

					result := input.Validate(nil)

					Expect(result).To(BeNil())
				})
			})

			When("kind is invalid", func() {
				It("returns error", func() {
					input := &Constraints{Kind: "invalid"}

					result := input.Validate(nil)

					Expect(result).To(MatchError(ContainSubstring("unknown constraint")))
				})
			})

			When("kind is validation set", func() {
				It("returns validation set validation result", func() {
					input := &Constraints{
						Kind:          ValidationSetConstraintsType,
						ValidationSet: &ValidationSet{"v1", "v2"}}

					result := input.Validate("v1")

					Expect(result).To(BeNil())
				})
			})

			When("kind is range", func() {
				It("returns range validation result", func() {
					input := &Constraints{
						Kind:        RangeConstraintsType,
						NumberRange: &Range{Min: 1, Max: 9}}

					result := input.Validate(8)

					Expect(result).To(BeNil())
				})
			})
		})
	})

	Describe("ValidationSet", func() {
		Describe("String", func() {
			When("validation set is nil", func() {
				It("returns error", func() {
					var input *ValidationSet

					result, err := input.String()

					Expect(err).To(MatchError(ContainSubstring("must not be nil")))
					Expect(result).To(BeEmpty())
				})
			})

			When("validation set is empty", func() {
				It("returns empty validation set as string", func() {
					input := &ValidationSet{}

					result, err := input.String()

					Expect(err).ToNot(HaveOccurred())
					Expect(result).To(Equal("[]"))
				})
			})

			When("validation set is not empty", func() {
				It("returns validation set as string", func() {
					input := &ValidationSet{"v1", "v2"}

					result, err := input.String()

					Expect(err).ToNot(HaveOccurred())
					Expect(result).To(Equal("[v1|v2]"))
				})
			})
		})

		Describe("Validate", func() {
			When("validation set is nil", func() {
				It("returns error", func() {
					var input *ValidationSet

					result := input.Validate("value")

					Expect(result).To(MatchError(ContainSubstring("must not be nil")))
				})
			})

			When("value is invalid", func() {
				It("returns validation error", func() {
					input := &ValidationSet{"v1", "v2"}

					result := input.Validate("invalid")

					Expect(result).To(MatchError(ContainSubstring("invalid value")))
				})
			})

			When("value is valid", func() {
				It("returns nil", func() {
					input := &ValidationSet{"v1", "v2"}

					result := input.Validate("v2")

					Expect(result).To(BeNil())
				})
			})
		})
	})

	Describe("Range", func() {
		Describe("String", func() {
			When("range is nil", func() {
				It("returns empty string", func() {
					var input *Range

					result, err := input.String()

					Expect(err).To(MatchError(ContainSubstring("must not be nil")))
					Expect(result).To(BeEmpty())
				})
			})

			When("range is not nil", func() {
				It("returns range as string", func() {
					input := &Range{Min: 1, Max: 9}

					result, err := input.String()

					Expect(err).ToNot(HaveOccurred())
					Expect(result).To(Equal("[1,9]"))
				})
			})
		})

		Describe("Validate", func() {
			When("range is nil", func() {
				It("returns error", func() {
					var input *Range

					result := input.Validate("value")

					Expect(result).To(MatchError(ContainSubstring("must not be nil")))
				})
			})

			When("value is not a number", func() {
				It("returns error", func() {
					input := &Range{}

					result := input.Validate("value")

					Expect(result).To(MatchError(ContainSubstring("not a number")))
				})
			})

			When("value is invalid", func() {
				It("returns validation error", func() {
					input := &Range{Min: 1, Max: 9}

					result := input.Validate(123)

					Expect(result).To(MatchError(ContainSubstring("out of range")))
				})
			})

			When("value is valid", func() {
				It("returns nil", func() {
					input := &Range{Min: 1, Max: 9}

					result := input.Validate(5)

					Expect(result).To(BeNil())
				})
			})
		})
	})

	Describe("loadAndValidate", func() {
		When("walkDir returns an error", func() {
			It("returns this error", func() {
				dir := "test-dir"
				expectedError := errors.New("oops")

				walkDirMock := &mockObject{}
				walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Return(expectedError)

				input := loadParams{
					directory: dir,
					walkDir:   walkDirMock.walkDir,
				}

				result, expectedError := loadAndValidate(input)

				Expect(expectedError).To(MatchError(expectedError))
				Expect(result).To(BeEmpty())
			})
		})

		When("walkDir finds addons", func() {
			It("returns the addons", func() {
				dir := "test-dir"
				path := filepath.Join(dir, "test-path")
				data := []byte{1, 2, 3}
				var genericJson any
				addon := Addon{Metadata: AddonMetadata{Name: "test-name", Description: "test-description"}, Spec: AddonSpec{Implementations: []Implementation{{Name: "test-implementation"}}}}

				schemaValidationMock := &mockObject{}
				schemaValidationMock.On(r.GetFunctionName(schemaValidationMock.validateAgainstSchema), genericJson).Return(nil)

				contentValidationMock := &mockObject{}
				contentValidationMock.On(r.GetFunctionName(contentValidationMock.validateContent), addon).Return(nil)

				unmarshalMock := &mockObject{}
				unmarshalMock.On(r.GetFunctionName(unmarshalMock.unmarshal), data, mock.AnythingOfType("*interface {}")).Run(func(args mock.Arguments) {
					genericJson = args.Get(1)
				}).Return(nil)
				unmarshalMock.On(r.GetFunctionName(unmarshalMock.unmarshal), data, mock.AnythingOfType("*addons.Addon")).Run(func(args mock.Arguments) {
					ap := args.Get(1).(*Addon)
					*ap = addon
				}).Return(nil)

				readFileMock := &mockObject{}
				readFileMock.On(r.GetFunctionName(readFileMock.readFile), path).Return(data, nil)

				dirEntryMock := &mockObject{}
				dirEntryMock.On(r.GetFunctionName(dirEntryMock.IsDir)).Return(false)
				dirEntryMock.On(r.GetFunctionName(dirEntryMock.Name)).Return("test-manifest")

				walkDirMock := &mockObject{}
				walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Run(func(args mock.Arguments) {
					walkFunc := args.Get(1).(fs.WalkDirFunc)
					err := walkFunc(path, dirEntryMock, nil)

					Expect(err).ToNot(HaveOccurred())
				}).Return(nil)

				input := loadParams{
					directory:             dir,
					walkDir:               walkDirMock.walkDir,
					manifestFileName:      "test-manifest",
					readFile:              readFileMock.readFile,
					unmarshal:             unmarshalMock.unmarshal,
					validateAgainstSchema: schemaValidationMock.validateAgainstSchema,
					validateContent:       contentValidationMock.validateContent,
				}

				result, err := loadAndValidate(input)

				Expect(err).ToNot(HaveOccurred())
				Expect(result).To(ConsistOf(Addon{
					Metadata: AddonMetadata{
						Name:        "test-name",
						Description: "test-description",
					},
					Directory: dir,
					Spec:      AddonSpec{Implementations: []Implementation{{Name: "test-implementation", Directory: filepath.Join(dir, "test-implementation"), ExportDirectoryName: "test-name-test-implementation", AddonsCmdName: ("test-name" + " " + "test-implementation")}}},
				}))
			})
		})

		Describe("walkDir", func() {
			When("previous error detected", func() {
				It("returns this error", func() {
					dir := "test-dir"
					expectedError := errors.New("oops")

					walkDirMock := &mockObject{}
					walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Run(func(args mock.Arguments) {
						walkFunc := args.Get(1).(fs.WalkDirFunc)
						err := walkFunc("", nil, expectedError)

						Expect(err).To(MatchError(expectedError))
					}).Return(nil).Once()

					input := loadParams{
						directory: dir,
						walkDir:   walkDirMock.walkDir,
					}

					result, _ := loadAndValidate(input)

					Expect(result).To(BeEmpty())

					walkDirMock.AssertExpectations(GinkgoT())
				})
			})

			When("no files found", func() {
				It("returns empty sclice", func() {
					dir := "test-dir"

					dirEntryMock := &mockObject{}
					dirEntryMock.On(r.GetFunctionName(dirEntryMock.IsDir)).Return(true).Once()

					walkDirMock := &mockObject{}
					walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Run(func(args mock.Arguments) {
						walkFunc := args.Get(1).(fs.WalkDirFunc)
						err := walkFunc("", dirEntryMock, nil)

						Expect(err).ToNot(HaveOccurred())
					}).Return(nil)

					input := loadParams{
						directory: dir,
						walkDir:   walkDirMock.walkDir,
					}

					result, err := loadAndValidate(input)

					Expect(err).ToNot(HaveOccurred())
					Expect(result).To(BeEmpty())

					dirEntryMock.AssertExpectations(GinkgoT())
				})
			})

			When("files found, but file name does not match", func() {
				It("returns empty sclice", func() {
					dir := "test-dir"

					dirEntryMock := &mockObject{}
					dirEntryMock.On(r.GetFunctionName(dirEntryMock.IsDir)).Return(false).Once()
					dirEntryMock.On(r.GetFunctionName(dirEntryMock.Name)).Return("not-a-manifest-file").Once()

					walkDirMock := &mockObject{}
					walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Run(func(args mock.Arguments) {
						walkFunc := args.Get(1).(fs.WalkDirFunc)
						err := walkFunc("", dirEntryMock, nil)

						Expect(err).ToNot(HaveOccurred())
					}).Return(nil)

					input := loadParams{
						directory:        dir,
						walkDir:          walkDirMock.walkDir,
						manifestFileName: "test-manifest",
					}

					result, err := loadAndValidate(input)

					Expect(err).ToNot(HaveOccurred())
					Expect(result).To(BeEmpty())

					dirEntryMock.AssertExpectations(GinkgoT())
				})
			})

			When("file read error occurred", func() {
				It("returns this error", func() {
					dir := "test-dir"
					path := "test-path"
					expectedError := errors.New("oops")

					readFileMock := &mockObject{}
					readFileMock.On(r.GetFunctionName(readFileMock.readFile), path).Return([]byte{}, expectedError)

					dirEntryMock := &mockObject{}
					dirEntryMock.On(r.GetFunctionName(dirEntryMock.IsDir)).Return(false)
					dirEntryMock.On(r.GetFunctionName(dirEntryMock.Name)).Return("test-manifest")

					walkDirMock := &mockObject{}
					walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Run(func(args mock.Arguments) {
						walkFunc := args.Get(1).(fs.WalkDirFunc)
						err := walkFunc(path, dirEntryMock, nil)

						Expect(err).To(MatchError(expectedError))
					}).Return(nil)

					input := loadParams{
						directory:        dir,
						walkDir:          walkDirMock.walkDir,
						manifestFileName: "test-manifest",
						readFile:         readFileMock.readFile,
					}

					result, _ := loadAndValidate(input)

					Expect(result).To(BeEmpty())
				})
			})

			When("unmarshal into generic json error occurred", func() {
				It("returns this error", func() {
					dir := "test-dir"
					path := "test-path"
					data := []byte{1, 2, 3}
					expectedError := errors.New("oops")

					unmarshalMock := &mockObject{}
					unmarshalMock.On(r.GetFunctionName(unmarshalMock.unmarshal), data, mock.AnythingOfType("*interface {}")).Return(expectedError)

					readFileMock := &mockObject{}
					readFileMock.On(r.GetFunctionName(readFileMock.readFile), path).Return(data, nil)

					dirEntryMock := &mockObject{}
					dirEntryMock.On(r.GetFunctionName(dirEntryMock.IsDir)).Return(false)
					dirEntryMock.On(r.GetFunctionName(dirEntryMock.Name)).Return("test-manifest")

					walkDirMock := &mockObject{}
					walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Run(func(args mock.Arguments) {
						walkFunc := args.Get(1).(fs.WalkDirFunc)
						err := walkFunc(path, dirEntryMock, nil)

						Expect(err).To(MatchError(expectedError))
					}).Return(nil)

					input := loadParams{
						directory:        dir,
						walkDir:          walkDirMock.walkDir,
						manifestFileName: "test-manifest",
						readFile:         readFileMock.readFile,
						unmarshal:        unmarshalMock.unmarshal,
					}

					result, _ := loadAndValidate(input)

					Expect(result).To(BeEmpty())
				})

				When("schema validation error occurred", func() {
					It("returns this error", func() {
						dir := "test-dir"
						path := "test-path"
						data := []byte{1, 2, 3}
						var genericJson any
						expectedError := errors.New("oops")

						schemaValidationMock := &mockObject{}
						schemaValidationMock.On(r.GetFunctionName(schemaValidationMock.validateAgainstSchema), genericJson).Return(expectedError)

						unmarshalMock := &mockObject{}
						unmarshalMock.On(r.GetFunctionName(unmarshalMock.unmarshal), data, mock.AnythingOfType("*interface {}")).Run(func(args mock.Arguments) {
							genericJson = args.Get(1)
						}).Return(nil)

						readFileMock := &mockObject{}
						readFileMock.On(r.GetFunctionName(readFileMock.readFile), path).Return(data, nil)

						dirEntryMock := &mockObject{}
						dirEntryMock.On(r.GetFunctionName(dirEntryMock.IsDir)).Return(false)
						dirEntryMock.On(r.GetFunctionName(dirEntryMock.Name)).Return("test-manifest")

						walkDirMock := &mockObject{}
						walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Run(func(args mock.Arguments) {
							walkFunc := args.Get(1).(fs.WalkDirFunc)
							err := walkFunc(path, dirEntryMock, nil)

							Expect(err).To(MatchError(ContainSubstring(expectedError.Error())))
						}).Return(nil)

						input := loadParams{
							directory:             dir,
							walkDir:               walkDirMock.walkDir,
							manifestFileName:      "test-manifest",
							readFile:              readFileMock.readFile,
							unmarshal:             unmarshalMock.unmarshal,
							validateAgainstSchema: schemaValidationMock.validateAgainstSchema,
						}

						result, _ := loadAndValidate(input)

						Expect(result).To(BeEmpty())
					})
				})

				When("unmarshal into addon error occurred", func() {
					It("returns this error", func() {
						dir := "test-dir"
						path := "test-path"
						data := []byte{1, 2, 3}
						var genericJson any
						expectedError := errors.New("oops")

						schemaValidationMock := &mockObject{}
						schemaValidationMock.On(r.GetFunctionName(schemaValidationMock.validateAgainstSchema), genericJson).Return(nil)

						unmarshalMock := &mockObject{}
						unmarshalMock.On(r.GetFunctionName(unmarshalMock.unmarshal), data, mock.AnythingOfType("*interface {}")).Run(func(args mock.Arguments) {
							genericJson = args.Get(1)
						}).Return(nil)
						unmarshalMock.On(r.GetFunctionName(unmarshalMock.unmarshal), data, mock.AnythingOfType("*addons.Addon")).Return(expectedError)

						readFileMock := &mockObject{}
						readFileMock.On(r.GetFunctionName(readFileMock.readFile), path).Return(data, nil)

						dirEntryMock := &mockObject{}
						dirEntryMock.On(r.GetFunctionName(dirEntryMock.IsDir)).Return(false)
						dirEntryMock.On(r.GetFunctionName(dirEntryMock.Name)).Return("test-manifest")

						walkDirMock := &mockObject{}
						walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Run(func(args mock.Arguments) {
							walkFunc := args.Get(1).(fs.WalkDirFunc)
							err := walkFunc(path, dirEntryMock, nil)

							Expect(err).To(MatchError(expectedError))
						}).Return(nil)

						input := loadParams{
							directory:             dir,
							walkDir:               walkDirMock.walkDir,
							manifestFileName:      "test-manifest",
							readFile:              readFileMock.readFile,
							unmarshal:             unmarshalMock.unmarshal,
							validateAgainstSchema: schemaValidationMock.validateAgainstSchema,
						}

						result, _ := loadAndValidate(input)

						Expect(result).To(BeEmpty())
					})
				})

				When("content validation error occurred", func() {
					It("returns this error", func() {
						dir := "test-dir"
						path := "test-path"
						data := []byte{1, 2, 3}
						var genericJson any
						addon := Addon{Metadata: AddonMetadata{Name: "test-name", Description: "test-description"}}
						expectedError := errors.New("oops")

						schemaValidationMock := &mockObject{}
						schemaValidationMock.On(r.GetFunctionName(schemaValidationMock.validateAgainstSchema), genericJson).Return(nil)

						contentValidationMock := &mockObject{}
						contentValidationMock.On(r.GetFunctionName(contentValidationMock.validateContent), addon).Return(expectedError)

						unmarshalMock := &mockObject{}
						unmarshalMock.On(r.GetFunctionName(unmarshalMock.unmarshal), data, mock.AnythingOfType("*interface {}")).Run(func(args mock.Arguments) {
							genericJson = args.Get(1)
						}).Return(nil)
						unmarshalMock.On(r.GetFunctionName(unmarshalMock.unmarshal), data, mock.AnythingOfType("*addons.Addon")).Run(func(args mock.Arguments) {
							ap := args.Get(1).(*Addon)
							*ap = addon
						}).Return(nil)

						readFileMock := &mockObject{}
						readFileMock.On(r.GetFunctionName(readFileMock.readFile), path).Return(data, nil)

						dirEntryMock := &mockObject{}
						dirEntryMock.On(r.GetFunctionName(dirEntryMock.IsDir)).Return(false)
						dirEntryMock.On(r.GetFunctionName(dirEntryMock.Name)).Return("test-manifest")

						walkDirMock := &mockObject{}
						walkDirMock.On(r.GetFunctionName(walkDirMock.walkDir), dir, mock.Anything).Run(func(args mock.Arguments) {
							walkFunc := args.Get(1).(fs.WalkDirFunc)
							err := walkFunc(path, dirEntryMock, nil)

							Expect(err).To(MatchError(expectedError))
						}).Return(nil)

						input := loadParams{
							directory:             dir,
							walkDir:               walkDirMock.walkDir,
							manifestFileName:      "test-manifest",
							readFile:              readFileMock.readFile,
							unmarshal:             unmarshalMock.unmarshal,
							validateAgainstSchema: schemaValidationMock.validateAgainstSchema,
							validateContent:       contentValidationMock.validateContent,
						}

						result, _ := loadAndValidate(input)

						Expect(result).To(BeEmpty())
					})
				})
			})
		})
	})
})
