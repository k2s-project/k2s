// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package setuporchestration

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestLibvirtTemplate(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "libvirt template Unit Tests", Label("unit", "ci", "libvirt"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("loadLibvirtTemplateFromDir", Ordered, func() {
	const embeddedDefault = "<domain><name>{{.Name}}</name></domain>"

	type testData struct {
		Name string
	}

	When("no custom template exists on disk", func() {
		It("returns the embedded default template", func() {
			nonExistentDir := filepath.Join(GinkgoT().TempDir(), "no-such-dir")

			tmpl, err := loadLibvirtTemplateFromDir(nonExistentDir, "domain.xml.tmpl", embeddedDefault)

			Expect(err).ToNot(HaveOccurred())
			Expect(tmpl).ToNot(BeNil())

			var buf bytes.Buffer
			Expect(tmpl.Execute(&buf, testData{Name: "test-vm"})).To(Succeed())
			Expect(buf.String()).To(Equal("<domain><name>test-vm</name></domain>"))
		})
	})

	When("a custom template exists on disk", func() {
		var customDir string

		BeforeEach(func() {
			customDir = GinkgoT().TempDir()
			customContent := "<domain type='kvm'><name>{{.Name}}</name><custom/></domain>"
			Expect(os.WriteFile(filepath.Join(customDir, "domain.xml.tmpl"), []byte(customContent), 0644)).To(Succeed())
		})

		It("uses the custom template instead of the embedded default", func() {
			tmpl, err := loadLibvirtTemplateFromDir(customDir, "domain.xml.tmpl", embeddedDefault)

			Expect(err).ToNot(HaveOccurred())
			Expect(tmpl).ToNot(BeNil())

			var buf bytes.Buffer
			Expect(tmpl.Execute(&buf, testData{Name: "custom-vm"})).To(Succeed())
			Expect(buf.String()).To(ContainSubstring("<custom/>"))
			Expect(buf.String()).To(ContainSubstring("<name>custom-vm</name>"))
		})
	})

	When("the custom template contains invalid Go template syntax", func() {
		var customDir string

		BeforeEach(func() {
			customDir = GinkgoT().TempDir()
			invalidContent := "<domain>{{.Unclosed"
			Expect(os.WriteFile(filepath.Join(customDir, "domain.xml.tmpl"), []byte(invalidContent), 0644)).To(Succeed())
		})

		It("returns a parse error", func() {
			tmpl, err := loadLibvirtTemplateFromDir(customDir, "domain.xml.tmpl", embeddedDefault)

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("failed to parse custom template"))
			Expect(tmpl).To(BeNil())
		})
	})

	When("the embedded default contains invalid Go template syntax", func() {
		It("returns a parse error", func() {
			nonExistentDir := filepath.Join(GinkgoT().TempDir(), "no-such-dir")
			badDefault := "<domain>{{.Unclosed"

			tmpl, err := loadLibvirtTemplateFromDir(nonExistentDir, "domain.xml.tmpl", badDefault)

			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("failed to parse embedded template"))
			Expect(tmpl).To(BeNil())
		})
	})

	When("the custom directory exists but the specific template file does not", func() {
		It("falls back to the embedded default", func() {
			emptyDir := GinkgoT().TempDir()

			tmpl, err := loadLibvirtTemplateFromDir(emptyDir, "network.xml.tmpl", embeddedDefault)

			Expect(err).ToNot(HaveOccurred())
			Expect(tmpl).ToNot(BeNil())

			var buf bytes.Buffer
			Expect(tmpl.Execute(&buf, testData{Name: "fallback-vm"})).To(Succeed())
			Expect(buf.String()).To(Equal("<domain><name>fallback-vm</name></domain>"))
		})
	})

	Describe("embedded default templates", func() {
		It("parses the embedded domain XML template without error", func() {
			nonExistentDir := filepath.Join(GinkgoT().TempDir(), "no-such-dir")

			tmpl, err := loadLibvirtTemplateFromDir(nonExistentDir, "domain.xml.tmpl", domainXMLTemplate)

			Expect(err).ToNot(HaveOccurred())
			Expect(tmpl).ToNot(BeNil())

			var buf bytes.Buffer
			data := domainTemplateData{
				Name:          "k2s-win-test",
				MemoryKB:      4194304,
				CPUCount:      2,
				DiskPath:      "/var/lib/k2s/images/win.qcow2",
				NetworkBridge:  "k2s",
				FirmwarePath:  "/usr/share/OVMF/OVMF_CODE.fd",
				NVRAMPath:     "/var/lib/k2s/images/win_VARS.fd",
				MACAddress:    "52:54:00:25:57:01",
			}
			Expect(tmpl.Execute(&buf, data)).To(Succeed())

			rendered := buf.String()
			Expect(rendered).To(ContainSubstring("<name>k2s-win-test</name>"))
			Expect(rendered).To(ContainSubstring("<memory unit='KiB'>4194304</memory>"))
			Expect(rendered).To(ContainSubstring("<vcpu placement='static'>2</vcpu>"))
			Expect(rendered).To(ContainSubstring("/var/lib/k2s/images/win.qcow2"))
			Expect(rendered).To(ContainSubstring("network='k2s'"))
			Expect(rendered).To(ContainSubstring("mac address='52:54:00:25:57:01'"))
			Expect(rendered).To(ContainSubstring("OVMF_CODE.fd"))
		})

		It("parses the embedded network XML template without error", func() {
			nonExistentDir := filepath.Join(GinkgoT().TempDir(), "no-such-dir")

			tmpl, err := loadLibvirtTemplateFromDir(nonExistentDir, "network.xml.tmpl", networkXMLTemplate)

			Expect(err).ToNot(HaveOccurred())
			Expect(tmpl).ToNot(BeNil())

			var buf bytes.Buffer
			data := networkTemplateData{
				Name:           "k2s",
				BridgeName:     "virbr-k2s",
				HostIP:         "172.19.1.1",
				Netmask:        "255.255.255.0",
				DHCPRangeStart: "172.19.1.100",
				DHCPRangeEnd:   "172.19.1.199",
				WinVMIP:        "172.19.1.101",
				WinVMMac:       "52:54:00:25:57:01",
			}
			Expect(tmpl.Execute(&buf, data)).To(Succeed())

			rendered := buf.String()
			Expect(rendered).To(ContainSubstring("<name>k2s</name>"))
			Expect(rendered).To(ContainSubstring("name='virbr-k2s'"))
			Expect(rendered).To(ContainSubstring("address='172.19.1.1'"))
			Expect(rendered).To(ContainSubstring("start='172.19.1.100'"))
			Expect(rendered).To(ContainSubstring("end='172.19.1.199'"))
			Expect(rendered).To(ContainSubstring("ip='172.19.1.101'"))
			Expect(rendered).To(ContainSubstring("mac='52:54:00:25:57:01'"))
		})
	})
})
