// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"debug/buildinfo"
	"fmt"
	"os"
	"strings"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: read-go-buildinfo <executable>")
		os.Exit(2)
	}

	executable := os.Args[1]
	info, err := buildinfo.ReadFile(executable)
	if err != nil {
		os.Exit(1)
	}

	if version := strings.TrimPrefix(info.GoVersion, "go"); version != "" {
		fmt.Printf("pkg:golang/stdlib@v%s\t%s\n", version, executable)
	}

	for _, dependency := range info.Deps {
		module := dependency
		if dependency.Replace != nil {
			module = dependency.Replace
		}
		if module.Path != "" && module.Version != "" {
			fmt.Printf("pkg:golang/%s@%s\t%s\n", module.Path, module.Version, executable)
		}
	}
}
