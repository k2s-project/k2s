// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const proxyExecutable = "linkerd2-proxy.exe"
const bootstrapOnlyEnvironment = "LINKERD2_PROXY_IDENTITY_BOOTSTRAP_ONLY"
const identityDirEnvironment = "LINKERD2_PROXY_IDENTITY_DIR"
const identityTokenFileEnvironment = "LINKERD2_PROXY_IDENTITY_TOKEN_FILE"

var executablePath = os.Executable

var commandRunner = func(name string, args ...string) *exec.Cmd {
	return exec.Command(name, args...)
}

func main() {
	if err := run(os.Args[1:], os.Getenv, os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintf(os.Stderr, "[LinkerdProxyIdentity] ERROR: %v\n", err)
		os.Exit(exitCode(err))
	}
}

func run(args []string, getenv func(string) string, stdin, stdout, stderr *os.File) error {
	isWindows := runtime.GOOS == "windows"
	systemDrive := getenv("SystemDrive")
	identityDir := normalizeUnixPath(getenv(identityDirEnvironment), systemDrive, isWindows)
	tokenFile := normalizeUnixPath(getenv(identityTokenFileEnvironment), systemDrive, isWindows)
	localName := getenv("LINKERD2_PROXY_IDENTITY_LOCAL_NAME")
	trustAnchors := getenv("LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS")

	if err := bootstrapIdentity(identityDir, localName, trustAnchors); err != nil {
		return err
	}
	if getenv(bootstrapOnlyEnvironment) == "1" {
		return nil
	}

	identityExecutable, err := executablePath()
	if err != nil {
		return fmt.Errorf("resolve proxy identity executable path: %w", err)
	}
	proxy := commandRunner(filepath.Join(filepath.Dir(identityExecutable), proxyExecutable), args...)
	proxy.Env = identityEnvironment(identityDir, tokenFile)
	proxy.Stdin = stdin
	proxy.Stdout = stdout
	proxy.Stderr = stderr
	if err := proxy.Run(); err != nil {
		return err
	}
	return nil
}

func normalizeUnixPath(path, systemDrive string, isWindows bool) string {
	if !isWindows || !strings.HasPrefix(path, "/") || strings.HasPrefix(path, "//") {
		return path
	}
	if systemDrive == "" {
		systemDrive = "C:"
	}
	systemDrive = strings.TrimRight(systemDrive, `\\/`)
	return filepath.FromSlash(systemDrive + path)
}

func identityEnvironment(identityDir, tokenFile string) []string {
	environment := make([]string, 0, len(os.Environ())+2)
	for _, value := range os.Environ() {
		if strings.HasPrefix(value, identityDirEnvironment+"=") || strings.HasPrefix(value, identityTokenFileEnvironment+"=") {
			continue
		}
		environment = append(environment, value)
	}
	return append(environment,
		identityDirEnvironment+"="+identityDir,
		identityTokenFileEnvironment+"="+tokenFile,
	)
}

func exitCode(err error) int {
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode()
	}
	return 1
}
