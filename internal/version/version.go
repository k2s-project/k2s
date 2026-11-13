// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package version

import (
	"fmt"
	"runtime"
)

// Version information set by link flags during build.
// We fall back to these default values when we build outside the build context (e.g. go run, go build, or go test).
var (
	version      = "99.99.99"             // value from VERSION file
	buildDate    = "1970-01-01T00:00:00Z" // output from `date -u +'%Y-%m-%dT%H:%M:%SZ'`
	gitCommit    = ""                     // output from `git rev-parse HEAD`
	gitTag       = ""                     // output from `git describe --tags HEAD` (if clean tree state)
	gitTreeState = ""                     // determined from `git status --porcelain`. either 'clean' or 'dirty'
)

// Version contains base version information
type Version struct {
	Version      string
	BuildDate    string
	GitCommit    string
	GitTag       string
	GitTreeState string
	GoVersion    string
	Compiler     string
	Platform     string
}

func (v Version) String() string {
	return v.Version
}

// GetVersion returns the version information
func GetVersion() Version {
	var versionStr string

	if gitCommit != "" && gitTag != "" && gitTreeState == "clean" {
		// if we have a clean tree state and the current commit is tagged, this is an official release.
		// (e.g v0.5.0)
		versionStr = gitTag
	} else {
		// otherwise formulate a version string based on metadata
		versionStr = "v" + version
		if len(gitCommit) >= 7 {
			versionStr += "+" + gitCommit[0:7]
			if gitTreeState != "clean" {
				versionStr += ".dirty"
			}
		} else {
			versionStr += "+unknown"
		}
	}

	return Version{
		Version:      versionStr,
		BuildDate:    buildDate,
		GitCommit:    gitCommit,
		GitTag:       gitTag,
		GitTreeState: gitTreeState,
		GoVersion:    runtime.Version(),
		Compiler:     runtime.Compiler,
		Platform:     fmt.Sprintf("%s/%s", runtime.GOOS, runtime.GOARCH),
	}
}

// Print prints the version for the given CLI. If no print function is provided, it defaults to fmt.Printf.
func (v Version) Print(cliName string, printFuncs ...func(format string, a ...any)) {
	printFunc := func(format string, a ...any) {
		fmt.Printf(format, a...)
	}
	if len(printFuncs) > 0 {
		printFunc = printFuncs[0]
	}

	printFunc("%s: %s\n", cliName, v)

	printFunc("  BuildDate: %s\n", v.BuildDate)
	printFunc("  GitCommit: %s\n", v.GitCommit)
	printFunc("  GitTreeState: %s\n", v.GitTreeState)
	if v.GitTag != "" {
		printFunc("  GitTag: %s\n", v.GitTag)
	}
	printFunc("  GoVersion: %s\n", v.GoVersion)
	printFunc("  Compiler: %s\n", v.Compiler)
	printFunc("  Platform: %s\n", v.Platform)
}
