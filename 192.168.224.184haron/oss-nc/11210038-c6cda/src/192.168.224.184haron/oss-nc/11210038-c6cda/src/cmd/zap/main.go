// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows
// +build windows

// Zap.exe helps forcefully delete containerd and docker image storage on windows node.

package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/k2s-project/k2s/internal/cli"
	ve "github.com/k2s-project/k2s/internal/version"

	"github.com/Microsoft/hcsshim"
)

const cliName = "zap"

func folderExists(path string) bool {
	_, err := os.Stat(path)
	if err == nil {
		return true
	}
	if os.IsNotExist(err) {
		return false
	}
	return true
}

func main() {
	var folder string
	flag.StringVar(&folder, "folder", "", "Folder to zap.")

	versionFlag := cli.NewVersionFlag(cliName)
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}
	if folder == "" {
		fmt.Println("Error: folder must be supplied")
		return
	}

	if folderExists(folder) {
		location, foldername := filepath.Split(folder)
		info := hcsshim.DriverInfo{
			HomeDir: location,
			Flavour: 0,
		}
		if err := hcsshim.DestroyLayer(info, foldername); err != nil {
			fmt.Println("ERROR: ", err)
		} else {
			fmt.Println("INFO: Zapped successfully")
		}
	} else {
		fmt.Println("ERROR: Folder does not exist")
	}
}
