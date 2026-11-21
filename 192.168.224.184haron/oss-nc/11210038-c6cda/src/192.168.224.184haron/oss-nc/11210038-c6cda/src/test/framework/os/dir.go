// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0
package os

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"time"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

func RootDir() (string, error) {
	_, currentFilePath, _, ok := runtime.Caller(0)
	if !ok {
		return "", errors.New("source file path could not be determined")
	}

	currentDir := filepath.Dir(currentFilePath)

	// Look for VERSION file to find the Root dir
	versionFileName := "VERSION"
	for {
		versionFilePath := filepath.Join(currentDir, versionFileName)
		if _, err := os.Stat(versionFilePath); err == nil {
			return currentDir, nil
		}

		// Move up one directory
		parentDir := filepath.Dir(currentDir)
		if parentDir == currentDir {
			// Reached the root without finding VERSION file
			return "", errors.New("VERSION file not found")
		}

		currentDir = parentDir
	}
}

func IsFileYoungerThan(duration time.Duration, rootDir string, name string) bool {
	fileIsYounger := false

	GinkgoWriter.Println("Checking if file <", name, "> in dir <", rootDir, "> is younger than <", duration, ">")

	err := filepath.WalkDir(rootDir, func(path string, info fs.DirEntry, _ error) error {
		GinkgoWriter.Println("Currently walking", "path", path)

		if info == nil {
			GinkgoWriter.Println("Dir/file info not yet available")
			return nil
		}

		fileInfo, err := info.Info()
		if err != nil {
			return fmt.Errorf("failed to get file info for %s: %w", path, err)
		}

		if isSymLink(fileInfo.Mode()) {
			GinkgoWriter.Println("Path <", path, "> is symbolic link")

			dir := symLinkToDir(path)

			fileIsYounger = IsFileYoungerThan(duration, dir, name)
		} else if isDesiredFile(name, fileInfo) {
			fileIsYounger = isFileYoungerThan(duration, fileInfo)
		}

		return nil
	})

	Expect(err).ToNot(HaveOccurred())

	return fileIsYounger
}

func IsFileExists(rootDir string, name string) bool {
	fileExists := false

	GinkgoWriter.Println("Checking if file <", name, "> exists in dir <", rootDir, ">")

	err := filepath.WalkDir(rootDir, func(path string, info fs.DirEntry, _ error) error {
		GinkgoWriter.Println("Currently walking", "path", path)

		if info == nil {
			GinkgoWriter.Println("Dir/file info not yet available")
			return nil
		}

		fileInfo, err := info.Info()
		if err != nil {
			return fmt.Errorf("failed to get file info for %s: %w", path, err)
		}

		if isSymLink(fileInfo.Mode()) {
			GinkgoWriter.Println("Path <", path, "> is symbolic link")

			dir := symLinkToDir(path)

			fileExists = IsFileExists(dir, name)
		} else if isDesiredFile(name, fileInfo) {
			fileExists = true
			return filepath.SkipAll
		}

		return nil
	})

	Expect(err).ToNot(HaveOccurred())

	return fileExists
}

func isSymLink(mode fs.FileMode) bool {
	return mode&os.ModeSymlink != 0
}

func symLinkToDir(link string) string {
	dir, err := os.Readlink(link)

	Expect(err).ToNot(HaveOccurred())

	return dir
}

func isDesiredFile(name string, info fs.FileInfo) bool {
	return !info.IsDir() && info.Name() == name
}

func isFileYoungerThan(duration time.Duration, info fs.FileInfo) bool {
	GinkgoWriter.Println("Checking if <", info.Name(), "> is younger than <", duration, ">..")

	isYounger := info.ModTime().After(time.Now().Add(-duration))

	GinkgoWriter.Println("Is younger: <", isYounger, ">")

	return isYounger
}

func IsEmptyDir(name string) (bool, error) {
	f, err := os.Open(name)
	if err != nil {
		return false, err
	}
	defer f.Close()

	_, err = f.Readdirnames(1)
	if err == io.EOF {
		return true, nil
	}
	return false, err
}

func GetFilesMatch(root, pattern string) ([]string, error) {
	var matches []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		if matched, err := filepath.Match(pattern, filepath.Base(path)); err != nil {
			return err
		} else if matched {
			matches = append(matches, path)
		}
		return nil
	})

	if err != nil {
		return nil, err
	}

	return matches, nil
}
