//go:build windows

package zzaddonharness

import (
	"bufio"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

type AddonImportConfig struct {
	ArtifactFile      string
	Names             []string
	Nodes             string
	Omit              []string
	ShowOutput        bool
	SshPrivateKeyPath string
}

type AddonExportConfig struct {
	OutputDir    string
	Names        []string
	OmitImages   bool
	OmitPackages bool
	ShowOutput   bool
}

var ErrNotSupported = errors.New("operation not supported on this platform")

type unsupportedError struct{ operation, reason string }

func (e *unsupportedError) Error() string        { return e.operation + " is not supported: " + e.reason }
func (e *unsupportedError) Is(target error) bool { return target == ErrNotSupported }

func NotSupportedError(operation, reason string) error { return &unsupportedError{operation, reason} }

type streamWriter interface {
	WriteStdOut(string)
	WriteStdErr(string)
	Flush()
}

type linuxAddonProvider struct {
	installDir, configDir string
	stdWriter             streamWriter
}

func getNodeName() string {
	h, err := os.Hostname()
	if err == nil && h != "" {
		return strings.ToLower(h)
	}
	return "linux"
}

var drive = regexp.MustCompile(`^([A-Za-z]):[\\/]`)

func posix(p string) string {
	if m := drive.FindStringSubmatch(p); m != nil {
		return "/" + strings.ToLower(m[1]) + "/" + filepath.ToSlash(p[3:])
	}
	return p
}

func (p *linuxAddonProvider) Import(cfg AddonImportConfig) error {
	args := []string{"--file", posix(cfg.ArtifactFile), "--config-dir", posix(p.configDir)}
	for _, name := range cfg.Names {
		args = append(args, "--addon", name)
	}
	for _, omit := range cfg.Omit {
		args = append(args, "--omit", omit)
	}
	if cfg.Nodes != "" {
		args = append(args, "--nodes", cfg.Nodes)
	}
	if cfg.SshPrivateKeyPath != "" {
		args = append(args, "--ssh-key", cfg.SshPrivateKeyPath)
	}
	return p.run("Import-Addon.sh", "addons import --node/--nodes", args, cfg.ShowOutput)
}

func (p *linuxAddonProvider) Export(cfg AddonExportConfig) error {
	args := []string{"--output-dir", posix(cfg.OutputDir)}
	for _, name := range cfg.Names {
		args = append(args, "--addon", name)
	}
	if cfg.OmitImages {
		args = append(args, "--omit-images")
	}
	if cfg.OmitPackages {
		args = append(args, "--omit-packages")
	}
	return p.run("Export-Addon.sh", "addons export", args, cfg.ShowOutput)
}

func (p *linuxAddonProvider) run(name, operation string, args []string, showOutput bool) error {
	script := posix(filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "addon", name))
	cmd := exec.Command(`C:\Program Files\Git\usr\bin\bash.exe`, append([]string{script}, args...)...)
	cmd.Env = append(os.Environ(), "HOME="+posix(os.Getenv("HOME")))
	if showOutput {
		cmd.Env = append(cmd.Env, "K2S_SHOW_LOGS=true")
	}
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		return err
	}
	var lastError string
	var wg sync.WaitGroup
	read := func(r io.Reader, isErr bool) {
		defer wg.Done()
		s := bufio.NewScanner(r)
		for s.Scan() {
			line := s.Text()
			if isErr {
				if t := strings.TrimSpace(line); t != "" {
					lastError = t
				}
				if p.stdWriter != nil {
					p.stdWriter.WriteStdErr(line)
				}
			} else if p.stdWriter != nil {
				p.stdWriter.WriteStdOut(line)
			}
		}
	}
	wg.Add(2)
	go read(stdout, false)
	go read(stderr, true)
	wg.Wait()
	err := cmd.Wait()
	if err == nil {
		return nil
	}
	if lastError == "" {
		lastError = err.Error()
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) && exitErr.ExitCode() == 3 {
		return NotSupportedError(operation, lastError)
	}
	return errors.New(lastError)
}