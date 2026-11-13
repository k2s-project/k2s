// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cert

import "path/filepath"

func DetermineLocalCertPaths(localDir string, remoteCmd RemoteCertCmd) (certPath, keyPath string) {
	tempDirName := filepath.Base(remoteCmd.TempDir)
	certPath = filepath.Join(localDir, tempDirName, remoteCmd.CertFileName)
	keyPath = filepath.Join(localDir, tempDirName, remoteCmd.KeyFileName)
	return
}
