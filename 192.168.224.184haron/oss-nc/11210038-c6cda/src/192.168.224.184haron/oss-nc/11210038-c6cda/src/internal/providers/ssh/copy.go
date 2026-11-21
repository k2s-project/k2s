// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package ssh

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/pkg/sftp"
	"github.com/k2s-project/k2s/internal/host"
)

type copier interface {
	CopyFile(source, target string) error
	CopyDir(source, target string) error
}

type basicCopier struct {
	deleteSource bool
	client       *sftp.Client
}

type toRemoteCopier struct {
	basicCopier
}

type fromRemoteCopier struct {
	basicCopier
}

type pathInfo struct {
	path  string
	isDir bool
}

type targetInfo struct {
	pathInfo
	isExisting bool
}

func (s *SSH) CopyToNode(source, target string) error {
	return copyToRemote(source, target, s.connectionOptions, false)
}
func (s *SSH) CopyFromNode(source, target string) error {
	return copyFromRemote(source, target, s.connectionOptions, false)
}

func (s *SSH) MoveToNode(source, target string) error {
	return copyToRemote(source, target, s.connectionOptions, true)
}
func (s *SSH) MoveFromNode(source, target string) error {
	return copyFromRemote(source, target, s.connectionOptions, true)
}

func (c *toRemoteCopier) CopyFile(source, target string) error {
	return c.copyFileToRemote(source, target)
}

func (c *toRemoteCopier) CopyDir(source, target string) error {
	return c.copyDirToRemote(source, target)
}

func (c *fromRemoteCopier) CopyFile(source, target string) error {
	return c.copyFileFromRemote(source, target)
}

func (c *fromRemoteCopier) CopyDir(source, target string) error {
	return c.copyDirFromRemote(source, target)
}

func (c *toRemoteCopier) copyFileToRemote(localPath, remotePath string) error {
	slog.Debug("Copying file to remote", "local", localPath, "remote", remotePath)

	remoteFile, err := c.client.Create(remotePath)
	if err != nil {
		return fmt.Errorf("failed to create/open remote file '%s': %w", remotePath, err)
	}
	defer func() {
		if err := remoteFile.Close(); err != nil {
			slog.Error("failed to close remote file", "error", err, "path", remotePath)
		}
	}()

	localFile, err := os.Open(localPath)
	if err != nil {
		return fmt.Errorf("failed to open local file '%s': %w", localPath, err)
	}
	defer func() {
		if err := localFile.Close(); err != nil {
			slog.Error("failed to close local file", "error", err, "path", localPath)
		}
	}()

	bytesCopied, err := io.Copy(remoteFile, localFile)
	if err != nil {
		return fmt.Errorf("failed to copy '%s' to '%s': %w", localPath, remotePath, err)
	}
	slog.Debug("Copied file to remote", "local", localPath, "remote", remotePath, "bytes", bytesCopied)

	if c.deleteSource {
		slog.Debug("Deleting source file", "local", localPath)

		if err := os.RemoveAll(localPath); err != nil {
			return fmt.Errorf("failed to delete source file '%s': %w", localPath, err)
		}

		slog.Debug("Source file deleted", "local", localPath)
	}
	return nil
}

func (c *fromRemoteCopier) copyFileFromRemote(remotePath, localPath string) error {
	slog.Debug("Copying file to local", "local", localPath, "remote", remotePath)

	remoteFile, err := c.client.Open(remotePath)
	if err != nil {
		return fmt.Errorf("failed to open remote file '%s': %w", remotePath, err)
	}
	defer func() {
		if err := remoteFile.Close(); err != nil {
			slog.Error("failed to close remote file", "error", err, "path", remotePath)
		}
	}()

	localFile, err := os.Create(localPath)
	if err != nil {
		return fmt.Errorf("failed to create/open local file '%s': %w", localPath, err)
	}
	defer func() {
		if err := localFile.Close(); err != nil {
			slog.Error("failed to close local file", "error", err, "path", localPath)
		}
	}()

	bytesCopied, err := io.Copy(localFile, remoteFile)
	if err != nil {
		return fmt.Errorf("failed to copy '%s' to '%s': %w", remotePath, localPath, err)
	}
	slog.Debug("Copied file to local", "local", localPath, "remote", remotePath, "bytes", bytesCopied)

	if c.deleteSource {
		slog.Debug("Deleting source file", "remote", remotePath)

		if err := c.client.RemoveAll(remotePath); err != nil {
			return fmt.Errorf("failed to delete source file '%s': %w", remotePath, err)
		}

		slog.Debug("Source file deleted", "remote", remotePath)
	}
	return nil
}

func (c *toRemoteCopier) copyDirToRemote(localDir, remoteDir string) error {
	slog.Debug("Copying dir to remote", "local", localDir, "remote", remoteDir)

	err := filepath.WalkDir(localDir, func(localPath string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("failed to walk local dir '%s': %w", localDir, err)
		}

		localPath = filepath.ToSlash(localPath)

		relativePath, err := filepath.Rel(localDir, localPath)
		if err != nil {
			return fmt.Errorf("failed to determine relative path of '%s': %w", localPath, err)
		}

		remotePath := path.Join(remoteDir, filepath.ToSlash(relativePath))

		if d.IsDir() {
			slog.Debug("Creating remote dir", "path", remotePath)

			if err := c.client.MkdirAll(remotePath); err != nil {
				return fmt.Errorf("failed to create remote dir '%s': %w", remotePath, err)
			}
			return nil
		}
		return c.copyFileToRemote(localPath, remotePath)
	})
	if err != nil {
		return fmt.Errorf("failed to copy dir '%s' to '%s': %w", localDir, remoteDir, err)
	}

	slog.Debug("Dir copied to remote", "local", localDir, "remote", remoteDir)

	if c.deleteSource {
		slog.Debug("Deleting source directory", "local", localDir)

		if err := os.RemoveAll(localDir); err != nil {
			return fmt.Errorf("failed to delete source directory '%s': %w", localDir, err)
		}

		slog.Debug("Source directory deleted", "local", localDir)
	}
	return nil
}

func (c *fromRemoteCopier) copyDirFromRemote(remoteDir, localDir string) error {
	slog.Debug("Copying dir to local", "local", localDir, "remote", remoteDir)

	walker := c.client.Walk(remoteDir)

	for walker.Step() {
		if err := walker.Err(); err != nil {
			return fmt.Errorf("failed to walk remote dir '%s': %w", remoteDir, err)
		}

		relativePath, err := filepath.Rel(remoteDir, walker.Path())
		if err != nil {
			return fmt.Errorf("failed to determine relative path of '%s': %w", walker.Path(), err)
		}

		localPath := path.Join(localDir, filepath.ToSlash(relativePath))

		if walker.Stat().IsDir() {
			slog.Debug("Creating local dir", "path", localPath)

			if err := os.MkdirAll(localPath, os.ModePerm); err != nil {
				return fmt.Errorf("failed to create local dir '%s': %w", localPath, err)
			}
			continue
		}
		if err := c.copyFileFromRemote(walker.Path(), localPath); err != nil {
			return err
		}
	}

	slog.Debug("Dir copied to local", "remote", remoteDir, "local", localDir)

	if c.deleteSource {
		slog.Debug("Deleting source directory", "remote", remoteDir)

		if err := c.client.RemoveAll(remoteDir); err != nil {
			return fmt.Errorf("failed to delete source directory '%s': %w", remoteDir, err)
		}

		slog.Debug("Source directory deleted", "remote", remoteDir)
	}
	return nil
}

func copyToRemote(source, target string, connectionOptions ConnectionOptions, deleteSource bool) error {
	sourceInfo, err := analyzeLocalSource(source)
	if err != nil {
		return fmt.Errorf("failed to analyze local source '%s': %w", source, err)
	}

	return withSftpClient(connectionOptions, func(sftpClient *sftp.Client) error {
		targetInfo, err := analyzeRemoteTarget(target, sftpClient)
		if err != nil {
			return fmt.Errorf("failed to analyze remote target '%s': %w", target, err)
		}
		fileCopier := &toRemoteCopier{
			client:       sftpClient,
			deleteSource: deleteSource,
		}

		return copySourceToTarget(*sourceInfo, *targetInfo, fileCopier)
	})
}

func copyFromRemote(source, target string, connectionOptions ConnectionOptions, deleteSource bool) error {
	targetInfo, err := analyzeLocalTarget(target)
	if err != nil {
		return fmt.Errorf("failed to analyze local target '%s': %w", target, err)
	}

	return withSftpClient(connectionOptions, func(sftpClient *sftp.Client) error {
		sourceInfo, err := analyzeRemoteSource(source, sftpClient)
		if err != nil {
			return fmt.Errorf("failed to analyze remote source '%s': %w", source, err)
		}
		fileCopier := &fromRemoteCopier{
			client:       sftpClient,
			deleteSource: deleteSource,
		}

		return copySourceToTarget(*sourceInfo, *targetInfo, fileCopier)
	})
}

func withSftpClient(connectionOptions ConnectionOptions, fn func(*sftp.Client) error) error {
	sshClient, err := Connect(connectionOptions)
	if err != nil {
		return fmt.Errorf("failed to dial SSH: %w", err)
	}
	defer func() {
		slog.Debug("Closing SSH client")
		if err := sshClient.Close(); err != nil {
			slog.Error("failed to close SSH client", "error", err)
		}
	}()

	sftpClient, err := sftp.NewClient(sshClient)
	if err != nil {
		return fmt.Errorf("failed to create SFTP client: %w", err)
	}
	slog.Debug("SFTP client created on top of SSH connection")
	defer func() {
		slog.Debug("Closing SFTP client")
		if err := sftpClient.Close(); err != nil {
			slog.Error("failed to close SFTP client", "error", err)
		}
	}()

	return fn(sftpClient)
}

func analyzeLocalSource(path string) (*pathInfo, error) {
	slog.Debug("Analyzing local source", "path", path)

	localPath, err := cleanLocalPath(path)
	if err != nil {
		return nil, fmt.Errorf("failed to clean local path '%s': %w", path, err)
	}

	slog.Debug("Local path cleaned", "path", localPath)

	info, err := os.Stat(localPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("source '%s' does not exist", localPath)
		}
		return nil, fmt.Errorf("failed to retrieve information about source '%s': %w", localPath, err)
	}
	return &pathInfo{
		path:  localPath,
		isDir: info.IsDir(),
	}, nil
}

func analyzeLocalTarget(targetPath string) (*targetInfo, error) {
	slog.Debug("Analyzing local target", "path", targetPath)

	localPath, err := cleanLocalPath(targetPath)
	if err != nil {
		return nil, fmt.Errorf("failed to clean local path '%s': %w", localPath, err)
	}

	slog.Debug("Local path cleaned", "path", localPath)

	info, err := os.Stat(localPath)
	if err == nil {
		target := &targetInfo{
			path:       localPath,
			isDir:      info.IsDir(),
			isExisting: true,
		}

		slog.Debug("Local target existing", "path", target.path, "is-dir", target.isDir)
		return target, nil
	}

	if !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("failed to check for local target '%s': %w", localPath, err)
	}

	slog.Debug("Local target not existing, checking for parent", "target", localPath)
	return analyzeLocalParent(localPath)
}

func analyzeLocalParent(targetPath string) (*targetInfo, error) {
	parent := path.Dir(targetPath)

	_, err := os.Stat(parent)
	if err == nil {
		slog.Debug("Local parent existing", "parent", parent)
		return &targetInfo{path: targetPath}, nil
	}
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("local parent not existing '%s' of target '%s' not existing", parent, targetPath)
	}
	return nil, fmt.Errorf("failed to check for local parent dir '%s': %w", parent, err)
}

func analyzeRemoteTarget(remotePath string, sftpClient *sftp.Client) (*targetInfo, error) {
	slog.Debug("Analyzing remote target", "path", remotePath)

	remotePath, err := cleanRemotePath(remotePath, sftpClient)
	if err != nil {
		return nil, fmt.Errorf("failed to clean remote path '%s': %w", remotePath, err)
	}

	info, err := sftpClient.Stat(remotePath)
	if err == nil {
		target := &targetInfo{
			path:       remotePath,
			isDir:      info.IsDir(),
			isExisting: true,
		}

		slog.Debug("Remote target existing", "path", target.path, "is-dir", target.isDir)
		return target, nil
	}

	if !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("failed to check for remote target '%s': %w", remotePath, err)
	}

	slog.Debug("Remote target not existing, checking for parent", "target", remotePath)
	return analyzeRemoteParent(remotePath, sftpClient)
}

func analyzeRemoteParent(targetPath string, sftpClient *sftp.Client) (*targetInfo, error) {
	parent := path.Dir(targetPath)

	_, err := sftpClient.Stat(parent)
	if err == nil {
		slog.Debug("Remote parent existing", "parent", parent)
		return &targetInfo{path: targetPath}, nil
	}
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("remote parent not existing '%s' of target '%s' not existing", parent, targetPath)
	}
	return nil, fmt.Errorf("failed to check for remote parent dir '%s': %w", parent, err)
}

func analyzeRemoteSource(remotePath string, sftpClient *sftp.Client) (*pathInfo, error) {
	slog.Debug("Analyzing remote source", "path", remotePath)

	remotePath, err := cleanRemotePath(remotePath, sftpClient)
	if err != nil {
		return nil, fmt.Errorf("failed to clean remote path '%s': %w", remotePath, err)
	}

	info, err := sftpClient.Stat(remotePath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("source '%s' does not exist", remotePath)
		}
		return nil, fmt.Errorf("failed to retrieve information about source '%s': %w", remotePath, err)
	}
	return &pathInfo{
		path:  remotePath,
		isDir: info.IsDir(),
	}, nil
}

func cleanLocalPath(localPath string) (string, error) {
	slog.Debug("Cleaning local path", "path", localPath)

	resolvedPath, err := host.ResolveTildePrefixForCurrentUser(localPath)
	if err != nil {
		return "", fmt.Errorf("failed to clean local path '%s': %w", localPath, err)
	}
	return path.Clean(filepath.ToSlash(resolvedPath)), nil
}

func cleanRemotePath(remotePath string, sftpClient *sftp.Client) (string, error) {
	slog.Debug("Cleaning remote path", "path", remotePath)

	remotePath, err := resolveTildePrefix(filepath.ToSlash(remotePath), sftpClient)
	if err != nil {
		return "", fmt.Errorf("failed to resolve tilde prefix in remote path '%s': %w", remotePath, err)
	}

	result := path.Clean(remotePath)

	slog.Debug("Remote path cleaned", "path", remotePath)

	return result, nil
}

func resolveTildePrefix(path string, sftpClient *sftp.Client) (string, error) {
	if !strings.HasPrefix(path, "~") {
		return path, nil
	}

	homeDir, err := sftpClient.Getwd()
	if err != nil {
		return "", fmt.Errorf("failed to determine home dir on node: %w", err)
	}

	if strings.HasPrefix(homeDir, "/home/") {
		slog.Debug("Linux remote home dir detected", "path", homeDir)
	} else {
		slog.Debug("Windows remote home dir detected", "path", homeDir)

		homeDir = strings.TrimPrefix(homeDir, "/")
	}
	return strings.Replace(path, "~", homeDir, 1), nil
}

func copySourceToTarget(source pathInfo, target targetInfo, copier copier) error {
	if source.isDir {
		return copyDir(source.path, target, copier)
	}
	return copyFile(source.path, target, copier)
}

func copyFile(source string, target targetInfo, copier copier) error {
	targetPath := target.path
	if target.isExisting && target.isDir {
		targetPath = path.Join(targetPath, path.Base(source))
	}
	return copier.CopyFile(source, targetPath)
}

func copyDir(source string, target targetInfo, copier copier) error {
	targetPath := target.path

	if target.isExisting {
		if !target.isDir {
			return fmt.Errorf("target '%s' is a file", target.path)
		}
		targetPath = path.Join(targetPath, path.Base(source))
	}
	return copier.CopyDir(source, targetPath)
}
