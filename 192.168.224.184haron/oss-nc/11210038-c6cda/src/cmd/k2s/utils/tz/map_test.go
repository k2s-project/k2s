// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package tz

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/k2s-project/k2s/internal/test/reflection"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockTimezonConfigHandler struct {
	mock.Mock
}

func (m *mockTimezonConfigHandler) CopyTo(newFile, orginalFile string) error {
	args := m.Called(newFile, orginalFile)
	return args.Error(0)
}

func (m *mockTimezonConfigHandler) Remove(file string) error {
	args := m.Called(file)
	return args.Error(0)
}

func newTimezoneConfigWorkspaceForTest(kubedir string, filehandler fileHandler) ConfigWorkspace {
	fileHandler := filehandler
	return &TimezoneConfigWorkspace{
		kubeDir:     kubedir,
		fileHandler: fileHandler,
	}
}

func TestTimezoneMap(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Timezone Unit Tests", Label("unit", "ci"))
}

var _ = Describe("timezonemap", func() {
	Describe("TimezoneConfigWorkspace", func() {
		When("CreateHandle is called", func() {
			It("CreateHandle returns a TimezoneConfigWorkspaceHandle", func() {
				fileHandler := &mockTimezonConfigHandler{}
				fileHandler.On(reflection.GetFunctionName(fileHandler.CopyTo), mock.Anything, mock.Anything).Return(nil)
				kubeDir := "C:\\.kube"
				sut := newTimezoneConfigWorkspaceForTest(kubeDir, fileHandler)

				handle, err := sut.CreateHandle()

				Expect(err).NotTo(HaveOccurred())
				Expect(handle).NotTo(BeNil())
			})

			It("FileHandler.CopyTo is invoked with correct arguments", func() {
				fileHandler := &mockTimezonConfigHandler{}
				kubeDir := "C:\\.kube"
				expectedNewFilePath := filepath.Join(kubeDir, TimezoneConfigFile)
				expectedOriginalFilePath := "embed/" + TimezoneConfigFile
				fileHandler.On(reflection.GetFunctionName(fileHandler.CopyTo), expectedNewFilePath, expectedOriginalFilePath).Return(nil)
				sut := newTimezoneConfigWorkspaceForTest(kubeDir, fileHandler)

				handle, err := sut.CreateHandle()

				Expect(err).NotTo(HaveOccurred())
				Expect(handle).NotTo(BeNil())

			})
		})

		When("CreateHandle is called and File handler is unable to copy file", func() {
			It("CreateHandle returns an error", func() {
				fileHandler := &mockTimezonConfigHandler{}
				fileHandler.On(reflection.GetFunctionName(fileHandler.CopyTo), mock.Anything, mock.Anything).Return(errors.New("failed"))
				kubeDir := "C:\\.kube"
				sut := newTimezoneConfigWorkspaceForTest(kubeDir, fileHandler)

				handle, err := sut.CreateHandle()

				Expect(err).NotTo(BeNil())
				Expect(handle).To(BeNil())

			})
		})
	})

	Describe("TimezoneConfigWorkspaceHandle", func() {
		When("Release is called", func() {
			It("FileHandler is invoked with correct path", func() {
				expectedFilePath := "C:\\.kube\\" + TimezoneConfigFile
				fileHandler := &mockTimezonConfigHandler{}
				fileHandler.On(reflection.GetFunctionName(fileHandler.Remove), expectedFilePath).Return(nil)
				sut := &TimezoneConfigWorkspaceHandle{
					timezoneConfigFilePath: expectedFilePath,
					fileHandler:            fileHandler,
				}

				err := sut.Release()

				Expect(err).To(BeNil())
			})
		})
	})
})
