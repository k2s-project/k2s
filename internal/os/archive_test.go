// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package os_test

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	bos "os"
	"path/filepath"
	"runtime"

	"github.com/k2s-project/k2s/internal/os"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Archive Utilities", func() {
	var tempDir string

	BeforeEach(func() {
		tempDir = GinkgoT().TempDir()
	})

	Describe("ExtractZip", func() {
		It("extracts files and directories correctly", func() {
			zipPath := filepath.Join(tempDir, "test.zip")
			destDir := filepath.Join(tempDir, "extracted")

			// Create a valid zip file
			zf, err := bos.Create(zipPath)
			Expect(err).ToNot(HaveOccurred())
			zw := zip.NewWriter(zf)

			// Add a directory entry
			_, err = zw.Create("sub/")
			Expect(err).ToNot(HaveOccurred())

			// Add a file in directory
			w, err := zw.Create("sub/hello.txt")
			Expect(err).ToNot(HaveOccurred())
			_, err = w.Write([]byte("hello world"))
			Expect(err).ToNot(HaveOccurred())

			// Add a root file
			w2, err := zw.Create("root.txt")
			Expect(err).ToNot(HaveOccurred())
			_, err = w2.Write([]byte("root content"))
			Expect(err).ToNot(HaveOccurred())

			Expect(zw.Close()).To(Succeed())
			Expect(zf.Close()).To(Succeed())

			// Extract
			err = os.ExtractZip(zipPath, destDir)
			Expect(err).ToNot(HaveOccurred())

			// Verify
			data1, err := bos.ReadFile(filepath.Join(destDir, "sub", "hello.txt"))
			Expect(err).ToNot(HaveOccurred())
			Expect(string(data1)).To(Equal("hello world"))

			data2, err := bos.ReadFile(filepath.Join(destDir, "root.txt"))
			Expect(err).ToNot(HaveOccurred())
			Expect(string(data2)).To(Equal("root content"))
		})

		It("returns an error for non-existent zip file", func() {
			err := os.ExtractZip(filepath.Join(tempDir, "nonexistent.zip"), filepath.Join(tempDir, "dest"))
			Expect(err).To(HaveOccurred())
		})

		It("blocks Zip-Slip path traversal attempts", func() {
			zipPath := filepath.Join(tempDir, "malicious.zip")
			destDir := filepath.Join(tempDir, "extracted")

			zf, err := bos.Create(zipPath)
			Expect(err).ToNot(HaveOccurred())
			zw := zip.NewWriter(zf)

			// Add path traversal entry
			w, err := zw.Create("../outside.txt")
			Expect(err).ToNot(HaveOccurred())
			_, err = w.Write([]byte("malicious content"))
			Expect(err).ToNot(HaveOccurred())

			Expect(zw.Close()).To(Succeed())
			Expect(zf.Close()).To(Succeed())

			err = os.ExtractZip(zipPath, destDir)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("Zip-Slip"))
		})

		It("rejects extraction through a destination symlink", func() {
			outside := GinkgoT().TempDir()
			destDir := filepath.Join(tempDir, "extracted")
			Expect(bos.MkdirAll(destDir, 0755)).To(Succeed())
			Expect(bos.Symlink(outside, filepath.Join(destDir, "link"))).To(Succeed())

			zipPath := filepath.Join(tempDir, "symlink.zip")
			zf, err := bos.Create(zipPath)
			Expect(err).ToNot(HaveOccurred())
			zw := zip.NewWriter(zf)
			w, err := zw.Create("link/subdir/outside.txt")
			Expect(err).ToNot(HaveOccurred())
			_, _ = w.Write([]byte("outside"))
			Expect(zw.Close()).To(Succeed())
			Expect(zf.Close()).To(Succeed())

			Expect(os.ExtractZip(zipPath, destDir)).ToNot(Succeed())
			Expect(filepath.Join(outside, "subdir")).ToNot(BeADirectory())
		})
	})

	Describe("ExtractTarGz", func() {
		It("extracts files and directories correctly", func() {
			tarGzPath := filepath.Join(tempDir, "test.tar.gz")
			destDir := filepath.Join(tempDir, "extracted")

			tf, err := bos.Create(tarGzPath)
			Expect(err).ToNot(HaveOccurred())
			gw := gzip.NewWriter(tf)
			tw := tar.NewWriter(gw)

			// Add dir
			Expect(tw.WriteHeader(&tar.Header{
				Name:     "sub/",
				Typeflag: tar.TypeDir,
				Mode:     0755,
			})).To(Succeed())

			// Add file
			content := []byte("tar gz content")
			Expect(tw.WriteHeader(&tar.Header{
				Name:     "sub/file.txt",
				Typeflag: tar.TypeReg,
				Size:     int64(len(content)),
				Mode:     0644,
			})).To(Succeed())
			_, err = tw.Write(content)
			Expect(err).ToNot(HaveOccurred())

			Expect(tw.Close()).To(Succeed())
			Expect(gw.Close()).To(Succeed())
			Expect(tf.Close()).To(Succeed())

			// Extract
			err = os.ExtractTarGz(tarGzPath, destDir)
			Expect(err).ToNot(HaveOccurred())

			// Verify
			data, err := bos.ReadFile(filepath.Join(destDir, "sub", "file.txt"))
			Expect(err).ToNot(HaveOccurred())
			Expect(string(data)).To(Equal("tar gz content"))
		})

		It("returns an error for non-existent tar.gz file", func() {
			err := os.ExtractTarGz(filepath.Join(tempDir, "nonexistent.tar.gz"), filepath.Join(tempDir, "dest"))
			Expect(err).To(HaveOccurred())
		})

		It("blocks Tar-Slip path traversal attempts", func() {
			tarGzPath := filepath.Join(tempDir, "malicious.tar.gz")
			destDir := filepath.Join(tempDir, "extracted")

			tf, err := bos.Create(tarGzPath)
			Expect(err).ToNot(HaveOccurred())
			gw := gzip.NewWriter(tf)
			tw := tar.NewWriter(gw)

			content := []byte("malicious")
			Expect(tw.WriteHeader(&tar.Header{
				Name:     "../../outside.txt",
				Typeflag: tar.TypeReg,
				Size:     int64(len(content)),
				Mode:     0644,
			})).To(Succeed())
			_, err = tw.Write(content)
			Expect(err).ToNot(HaveOccurred())

			Expect(tw.Close()).To(Succeed())
			Expect(gw.Close()).To(Succeed())
			Expect(tf.Close()).To(Succeed())

			err = os.ExtractTarGz(tarGzPath, destDir)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("Tar-Slip"))
		})

		It("blocks Tar-Slip via escaping relative symlink target", func() {
			tarGzPath := filepath.Join(tempDir, "malicious_symlink.tar.gz")
			destDir := filepath.Join(tempDir, "extracted")

			tf, err := bos.Create(tarGzPath)
			Expect(err).ToNot(HaveOccurred())
			gw := gzip.NewWriter(tf)
			tw := tar.NewWriter(gw)

			Expect(tw.WriteHeader(&tar.Header{
				Name:     "sub/link.txt",
				Linkname: "../../outside.txt",
				Typeflag: tar.TypeSymlink,
			})).To(Succeed())

			Expect(tw.Close()).To(Succeed())
			Expect(gw.Close()).To(Succeed())
			Expect(tf.Close()).To(Succeed())

			err = os.ExtractTarGz(tarGzPath, destDir)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("Tar-Slip"))
		})

		It("blocks absolute symlink target", func() {
			tarGzPath := filepath.Join(tempDir, "malicious_abs_symlink.tar.gz")
			destDir := filepath.Join(tempDir, "extracted")

			tf, err := bos.Create(tarGzPath)
			Expect(err).ToNot(HaveOccurred())
			gw := gzip.NewWriter(tf)
			tw := tar.NewWriter(gw)

			Expect(tw.WriteHeader(&tar.Header{
				Name:     "link.txt",
				Linkname: "/etc/passwd",
				Typeflag: tar.TypeSymlink,
			})).To(Succeed())

			Expect(tw.Close()).To(Succeed())
			Expect(gw.Close()).To(Succeed())
			Expect(tf.Close()).To(Succeed())

			err = os.ExtractTarGz(tarGzPath, destDir)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("absolute path"))
		})

		It("preserves literal backslashes in tar entry names on POSIX platforms", func() {
			if runtime.GOOS == "windows" {
				Skip("backslashes are path separators on Windows")
			}
			tarGzPath := filepath.Join(tempDir, "backslash.tar.gz")
			destDir := filepath.Join(tempDir, "extracted")

			tf, err := bos.Create(tarGzPath)
			Expect(err).ToNot(HaveOccurred())
			gw := gzip.NewWriter(tf)
			tw := tar.NewWriter(gw)

			literalContent := []byte("literal-backslash")
			Expect(tw.WriteHeader(&tar.Header{
				Name:     `logs\2024.txt`,
				Typeflag: tar.TypeReg,
				Size:     int64(len(literalContent)),
				Mode:     0644,
			})).To(Succeed())
			_, err = tw.Write(literalContent)
			Expect(err).ToNot(HaveOccurred())

			nestedContent := []byte("nested-slash")
			Expect(tw.WriteHeader(&tar.Header{
				Name:     "logs/2024.txt",
				Typeflag: tar.TypeReg,
				Size:     int64(len(nestedContent)),
				Mode:     0644,
			})).To(Succeed())
			_, err = tw.Write(nestedContent)
			Expect(err).ToNot(HaveOccurred())

			Expect(tw.Close()).To(Succeed())
			Expect(gw.Close()).To(Succeed())
			Expect(tf.Close()).To(Succeed())

			Expect(os.ExtractTarGz(tarGzPath, destDir)).To(Succeed())

			gotLiteral, err := bos.ReadFile(filepath.Join(destDir, `logs\2024.txt`))
			Expect(err).ToNot(HaveOccurred())
			Expect(string(gotLiteral)).To(Equal("literal-backslash"))

			gotNested, err := bos.ReadFile(filepath.Join(destDir, "logs", "2024.txt"))
			Expect(err).ToNot(HaveOccurred())
			Expect(string(gotNested)).To(Equal("nested-slash"))
		})
	})

	Describe("ExtractTarGz symlinked directories", func() {
		It("rejects writing through a pre-existing symlinked directory", func() {
			outside := GinkgoT().TempDir()
			dest := filepath.Join(tempDir, "dest")
			Expect(bos.MkdirAll(dest, 0755)).To(Succeed())
			Expect(bos.Symlink(outside, filepath.Join(dest, "esc"))).To(Succeed())

			archive := filepath.Join(tempDir, "a.tar.gz")
			f, err := bos.Create(archive)
			Expect(err).ToNot(HaveOccurred())
			gz := gzip.NewWriter(f)
			tw := tar.NewWriter(gz)
			Expect(tw.WriteHeader(&tar.Header{Name: "esc/file.txt", Typeflag: tar.TypeReg, Mode: 0644, Size: 1})).To(Succeed())
			_, _ = tw.Write([]byte("x"))
			Expect(tw.Close()).To(Succeed())
			Expect(gz.Close()).To(Succeed())
			Expect(f.Close()).To(Succeed())

			Expect(os.ExtractTarGz(archive, dest)).ToNot(Succeed())
			_, statErr := bos.Stat(filepath.Join(outside, "file.txt"))
			Expect(statErr).To(HaveOccurred())
		})
	})
	Describe("ExtractTarGz metadata and directory entries", func() {
		It("accepts a root directory entry and restores exact modes including 000", func() {
			if runtime.GOOS == "windows" {
				Skip("POSIX permission bits are not preserved on Windows")
			}
			archive := filepath.Join(tempDir, "m.tar.gz")
			f, err := bos.Create(archive)
			Expect(err).ToNot(HaveOccurred())
			gz := gzip.NewWriter(f)
			tw := tar.NewWriter(gz)
			Expect(tw.WriteHeader(&tar.Header{Name: "./", Typeflag: tar.TypeDir, Mode: 0755})).To(Succeed())
			Expect(tw.WriteHeader(&tar.Header{Name: "./locked/", Typeflag: tar.TypeDir, Mode: 0})).To(Succeed())
			Expect(tw.WriteHeader(&tar.Header{Name: "./locked/secret", Typeflag: tar.TypeReg, Mode: 0600, Size: 1})).To(Succeed())
			_, _ = tw.Write([]byte("x"))
			Expect(tw.WriteHeader(&tar.Header{Name: "./nomode", Typeflag: tar.TypeReg, Mode: 0, Size: 0})).To(Succeed())
			Expect(tw.Close()).To(Succeed())
			Expect(gz.Close()).To(Succeed())
			Expect(f.Close()).To(Succeed())

			dest := filepath.Join(tempDir, "dest")
			Expect(os.ExtractTarGz(archive, dest)).To(Succeed())

			info, err := bos.Stat(filepath.Join(dest, "nomode"))
			Expect(err).ToNot(HaveOccurred())
			Expect(info.Mode().Perm()).To(Equal(bos.FileMode(0)))
			info, err = bos.Lstat(filepath.Join(dest, "locked"))
			Expect(err).ToNot(HaveOccurred())
			Expect(info.Mode().Perm()).To(Equal(bos.FileMode(0)))
			Expect(bos.Chmod(filepath.Join(dest, "locked"), 0700)).To(Succeed())
			info, err = bos.Stat(filepath.Join(dest, "locked", "secret"))
			Expect(err).ToNot(HaveOccurred())
			Expect(info.Mode().Perm()).To(Equal(bos.FileMode(0600)))
		})
	})

	Describe("ExtractZip directory permissions", func() {
		It("creates directories with owner access even if the entry reports no execute bit", func() {
			zipPath := filepath.Join(tempDir, "d.zip")
			f, err := bos.Create(zipPath)
			Expect(err).ToNot(HaveOccurred())
			zw := zip.NewWriter(f)
			hdr := &zip.FileHeader{Name: "sub/"}
			hdr.SetMode(bos.ModeDir | 0666)
			_, err = zw.CreateHeader(hdr)
			Expect(err).ToNot(HaveOccurred())
			w, err := zw.Create("sub/file.txt")
			Expect(err).ToNot(HaveOccurred())
			_, _ = w.Write([]byte("x"))
			Expect(zw.Close()).To(Succeed())
			Expect(f.Close()).To(Succeed())

			dest := filepath.Join(tempDir, "dest")
			Expect(os.ExtractZip(zipPath, dest)).To(Succeed())
			Expect(filepath.Join(dest, "sub", "file.txt")).To(BeARegularFile())
		})
	})
})
