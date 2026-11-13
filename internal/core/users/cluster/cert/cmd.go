// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cert

import (
	"crypto/rand"
	"fmt"
	"path"

	"github.com/k2s-project/k2s/internal/definitions"
)

type RemoteCertCmd struct {
	Cmd          string
	TempDir      string
	KeyFileName  string
	CertFileName string
}

const (
	privateKeyBits = 4096
	certValidDays  = 365
	k8sCaCertPath  = "/etc/kubernetes/pki/ca.crt"
	k8sCaKeyPath   = "/etc/kubernetes/pki/ca.key"
)

func CreateRemoteCertCmd(userName string) RemoteCertCmd {
	tempRemoteDir := path.Join("/tmp/", rand.Text())
	keyFileName := userName + ".key"
	certFileName := userName + ".crt"

	keyRemotePath := path.Join(tempRemoteDir, keyFileName)
	certRemotePath := path.Join(tempRemoteDir, certFileName)
	signRequestPath := path.Join(tempRemoteDir, userName+".csr")

	createDirCmd := "mkdir " + tempRemoteDir
	generateKeyCmd := fmt.Sprintf("openssl genrsa -out %s %d 2>&1", keyRemotePath, privateKeyBits)
	createSignRequestCmd := fmt.Sprintf("openssl req -new -key %s -out %s -subj \"\"/CN=%s/O=%s\"\" 2>&1", keyRemotePath, signRequestPath, userName, definitions.K2sUserGroup)
	signCertCmd := fmt.Sprintf("sudo openssl x509 -req -in %s -CA %s -CAkey %s -CAcreateserial -out %s -days %d 2>&1", signRequestPath, k8sCaCertPath, k8sCaKeyPath, certRemotePath, certValidDays)
	removeSignRequestCmd := "rm -f " + signRequestPath

	remoteCmd := createDirCmd + " && " +
		generateKeyCmd + " && " +
		createSignRequestCmd + " && " +
		signCertCmd + " && " +
		removeSignRequestCmd

	return RemoteCertCmd{
		Cmd:          remoteCmd,
		TempDir:      tempRemoteDir,
		KeyFileName:  keyFileName,
		CertFileName: certFileName,
	}
}
