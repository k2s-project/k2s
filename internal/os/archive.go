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
			// owner rwx is required to populate the directory; some ZIP writers report 0666 for directories
			if err := bos.MkdirAll(cleanDestPath, f.Mode().Perm()|0700); err != nil {
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
// Archived permissions are restored exactly (including mode 000 and setuid/setgid/sticky bits). Archived numeric
// ownership (UID/GID) is restored when running as root on a platform that supports it.
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
	restoreOwner := bos.Geteuid() == 0

	// Directory metadata is applied after all entries are extracted, so restrictive modes (e.g. 000) do not block extraction.
	var dirs []tarDirEntry

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

		// A directory entry is validated against the directory itself, any other entry against its parent
		symlinkCheckPath := filepath.Dir(cleanDestPath)
		if hdr.Typeflag == tar.TypeDir {
			symlinkCheckPath = cleanDestPath
		}
		if err := ensureNoSymlinkEscape(cleanDestDir, symlinkCheckPath); err != nil {
			return fmt.Errorf("illegal path in tar archive (%s): %w", hdr.Name, err)
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := bos.MkdirAll(cleanDestPath, 0700); err != nil {
				return fmt.Errorf("failed to create directory '%s': %w", cleanDestPath, err)
			}
			dirs = append(dirs, tarDirEntry{path: cleanDestPath, hdr: hdr})
		case tar.TypeReg, tar.TypeRegA:
			if err := bos.MkdirAll(filepath.Dir(cleanDestPath), 0755); err != nil {
				return fmt.Errorf("failed to create parent directory for '%s': %w", cleanDestPath, err)
			}

			_ = bos.Remove(cleanDestPath)
			outFile, err := bos.OpenFile(cleanDestPath, bos.O_CREATE|bos.O_EXCL|bos.O_WRONLY, 0600)
			if err != nil {
				return fmt.Errorf("failed to create file '%s': %w", cleanDestPath, err)
			}

			if _, err := io.Copy(outFile, tr); err != nil {
				outFile.Close()
				return fmt.Errorf("failed to write file '%s': %w", cleanDestPath, err)
			}

			// metadata is applied through the open descriptor, so it cannot be redirected via a symlink
			if restoreOwner {
				if err := outFile.Chown(hdr.Uid, hdr.Gid); err != nil {
					outFile.Close()
					return fmt.Errorf("failed to restore ownership of file '%s': %w", cleanDestPath, err)
				}
			}
			if err := outFile.Chmod(tarFileMode(hdr.Mode)); err != nil {
				outFile.Close()
				return fmt.Errorf("failed to restore permissions of file '%s': %w", cleanDestPath, err)
			}
			if err := outFile.Close(); err != nil {
				return fmt.Errorf("failed to close file '%s': %w", cleanDestPath, err)
			}
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
			if restoreOwner {
				if err := bos.Lchown(cleanDestPath, hdr.Uid, hdr.Gid); err != nil {
					return fmt.Errorf("failed to restore ownership of symlink '%s': %w", cleanDestPath, err)
				}
			}
		default:
			// Skip unsupported header types safely
		}
	}

	for i := len(dirs) - 1; i >= 0; i-- {
		if err := applyTarDirMetadata(dirs[i], restoreOwner); err != nil {
			return err
		}
	}

	return nil
}

type tarDirEntry struct {
	path string
	hdr  *tar.Header
}

// tarFileMode converts the raw mode bits of a tar header to a FileMode including setuid, setgid and sticky bits.
func tarFileMode(raw int64) bos.FileMode {
	mode := bos.FileMode(raw & 0777)
	if raw&04000 != 0 {
		mode |= bos.ModeSetuid
	}
	if raw&02000 != 0 {
		mode |= bos.ModeSetgid
	}
	if raw&01000 != 0 {
		mode |= bos.ModeSticky
	}
	return mode
}

func applyTarDirMetadata(dir tarDirEntry, restoreOwner bool) error {
	info, err := bos.Lstat(dir.path)
	if err != nil {
		return fmt.Errorf("failed to inspect directory '%s': %w", dir.path, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("illegal path in tar archive: '%s' is not a directory", dir.path)
	}
	if restoreOwner {
		if err := bos.Lchown(dir.path, dir.hdr.Uid, dir.hdr.Gid); err != nil {
			return fmt.Errorf("failed to restore ownership of directory '%s': %w", dir.path, err)
		}
	}
	if err := bos.Chmod(dir.path, tarFileMode(dir.hdr.Mode)); err != nil {
		return fmt.Errorf("failed to restore permissions of directory '%s': %w", dir.path, err)
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
