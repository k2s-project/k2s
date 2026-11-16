// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package os

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	bos "os"
	"path/filepath"
	"strings"
)

// ExtractZip extracts all files from a ZIP archive to destDir, protecting against Zip-Slip attacks.
func ExtractZip(srcZip, destDir string) error {
	cleanDestDir := filepath.Clean(destDir)
	destPrefix := cleanDestDir + string(filepath.Separator)

	reader, err := zip.OpenReader(srcZip)
	if err != nil {
		return fmt.Errorf("failed to open zip file '%s': %w", srcZip, err)
	}
	defer reader.Close()

	if err := bos.MkdirAll(cleanDestDir, 0755); err != nil {
		return fmt.Errorf("failed to create destination directory '%s': %w", cleanDestDir, err)
	}

	for _, f := range reader.File {
		destPath := filepath.Join(cleanDestDir, f.Name)
		cleanDestPath := filepath.Clean(destPath)

		// Zip-Slip check: Ensure target path is within cleanDestDir
		if cleanDestPath != cleanDestDir && !strings.HasPrefix(cleanDestPath, destPrefix) {
			return fmt.Errorf("illegal file path in zip archive (Zip-Slip attempt): %s", f.Name)
		}

		if f.FileInfo().IsDir() {
			if err := bos.MkdirAll(cleanDestPath, f.Mode().Perm()); err != nil {
				return fmt.Errorf("failed to create directory '%s': %w", cleanDestPath, err)
			}
			continue
		}

		if err := bos.MkdirAll(filepath.Dir(cleanDestPath), 0755); err != nil {
			return fmt.Errorf("failed to create parent directory for '%s': %w", cleanDestPath, err)
		}

		if err := extractZipFile(f, cleanDestPath); err != nil {
			return err
		}
	}

	return nil
}

func extractZipFile(f *zip.File, destPath string) error {
	rc, err := f.Open()
	if err != nil {
		return fmt.Errorf("failed to open zip entry '%s': %w", f.Name, err)
	}
	defer rc.Close()

	mode := f.Mode().Perm()
	if mode == 0 {
		mode = 0644
	}

	outFile, err := bos.OpenFile(destPath, bos.O_CREATE|bos.O_TRUNC|bos.O_WRONLY, mode)
	if err != nil {
		return fmt.Errorf("failed to create file '%s': %w", destPath, err)
	}
	defer outFile.Close()

	if _, err := io.Copy(outFile, rc); err != nil {
		return fmt.Errorf("failed to write file '%s': %w", destPath, err)
	}

	return nil
}

// ExtractTarGz extracts all files from a tar.gz archive to destDir, protecting against Tar-Slip attacks.
func ExtractTarGz(srcTarGz, destDir string) error {
	cleanDestDir := filepath.Clean(destDir)
	destPrefix := cleanDestDir + string(filepath.Separator)

	file, err := bos.Open(srcTarGz)
	if err != nil {
		return fmt.Errorf("failed to open tar.gz file '%s': %w", srcTarGz, err)
	}
	defer file.Close()

	gzr, err := gzip.NewReader(file)
	if err != nil {
		return fmt.Errorf("failed to create gzip reader for '%s': %w", srcTarGz, err)
	}
	defer gzr.Close()

	if err := bos.MkdirAll(cleanDestDir, 0755); err != nil {
		return fmt.Errorf("failed to create destination directory '%s': %w", cleanDestDir, err)
	}

	tr := tar.NewReader(gzr)

	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("failed reading tar stream from '%s': %w", srcTarGz, err)
		}

		destPath := filepath.Join(cleanDestDir, hdr.Name)
		cleanDestPath := filepath.Clean(destPath)

		// Tar-Slip check: Ensure target path is within cleanDestDir
		if cleanDestPath != cleanDestDir && !strings.HasPrefix(cleanDestPath, destPrefix) {
			return fmt.Errorf("illegal file path in tar archive (Tar-Slip attempt): %s", hdr.Name)
		}

		if err := ensureNoSymlinkEscape(cleanDestDir, filepath.Dir(cleanDestPath)); err != nil {
			return fmt.Errorf("illegal path in tar archive (%s): %w", hdr.Name, err)
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			mode := bos.FileMode(hdr.Mode).Perm()
			if mode == 0 {
				mode = 0755
			}
			if err := bos.MkdirAll(cleanDestPath, mode); err != nil {
				return fmt.Errorf("failed to create directory '%s': %w", cleanDestPath, err)
			}
		case tar.TypeReg, tar.TypeRegA:
			if err := bos.MkdirAll(filepath.Dir(cleanDestPath), 0755); err != nil {
				return fmt.Errorf("failed to create parent directory for '%s': %w", cleanDestPath, err)
			}

			mode := bos.FileMode(hdr.Mode).Perm()
			if mode == 0 {
				mode = 0644
			}

			_ = bos.Remove(cleanDestPath)
			outFile, err := bos.OpenFile(cleanDestPath, bos.O_CREATE|bos.O_EXCL|bos.O_WRONLY, mode)
			if err != nil {
				return fmt.Errorf("failed to create file '%s': %w", cleanDestPath, err)
			}

			if _, err := io.Copy(outFile, tr); err != nil {
				outFile.Close()
				return fmt.Errorf("failed to write file '%s': %w", cleanDestPath, err)
			}
			outFile.Close()
		case tar.TypeSymlink:
			if strings.HasPrefix(hdr.Linkname, "/") || strings.HasPrefix(hdr.Linkname, "\\") || filepath.IsAbs(hdr.Linkname) || filepath.VolumeName(hdr.Linkname) != "" {
				return fmt.Errorf("illegal symlink target in tar archive (absolute path): %s -> %s", hdr.Name, hdr.Linkname)
			}
			linkDir := filepath.Dir(cleanDestPath)
			targetPath := filepath.Clean(filepath.Join(linkDir, hdr.Linkname))
			if targetPath != cleanDestDir && !strings.HasPrefix(targetPath, destPrefix) {
				return fmt.Errorf("illegal symlink target in tar archive (Tar-Slip attempt): %s -> %s", hdr.Name, hdr.Linkname)
			}
			if err := bos.MkdirAll(linkDir, 0755); err != nil {
				return fmt.Errorf("failed to create parent directory for symlink '%s': %w", cleanDestPath, err)
			}
			_ = bos.Remove(cleanDestPath)
			if err := bos.Symlink(hdr.Linkname, cleanDestPath); err != nil {
				return fmt.Errorf("failed to create symlink '%s' -> '%s': %w", cleanDestPath, hdr.Linkname, err)
			}
		default:
			// Skip unsupported header types safely
		}
	}

	return nil
}

// ensureNoSymlinkEscape verifies that the existing part of dir, after resolving symlinks, stays within root.
func ensureNoSymlinkEscape(root, dir string) error {
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return err
	}
	existing := dir
	for {
		if _, err := bos.Lstat(existing); err == nil {
			break
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			return nil
		}
		existing = parent
	}
	realDir, err := filepath.EvalSymlinks(existing)
	if err != nil {
		return err
	}
	if realDir != realRoot && !strings.HasPrefix(realDir, realRoot+string(filepath.Separator)) {
		return fmt.Errorf("path escapes destination via symlink")
	}
	return nil
}
