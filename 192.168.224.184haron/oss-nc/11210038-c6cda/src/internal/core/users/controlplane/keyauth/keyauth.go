// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package keyauth

import (
	"fmt"
	"log/slog"
	"path/filepath"
)

type sshProvider interface {
	Exec(command string) error
	CopyToNode(source, target string) error
}

type KeyAuthorizer struct {
	sshProvider sshProvider
}

const authorizedKeysPath = "~/.ssh/authorized_keys"

func NewKeyAuthorizer(sshProvider sshProvider) *KeyAuthorizer {
	return &KeyAuthorizer{sshProvider: sshProvider}
}

func (k *KeyAuthorizer) AuthorizePubKeyOnRemote(publicKeyPath, publicKeyComment string) error {
	slog.Debug("Authorizing public SSH key on remote machine", "path", publicKeyPath, "comment", publicKeyComment)

	pubKeyName := filepath.Base(publicKeyPath)
	remotePubKeyPath := "/tmp/" + pubKeyName
	removeRemotePubKeyCmd := "rm -f " + remotePubKeyPath

	slog.Debug("Removing existing public SSH key from remote machine", "path", remotePubKeyPath)
	if err := k.sshProvider.Exec(removeRemotePubKeyCmd); err != nil {
		return fmt.Errorf("failed to remove existing SSH public key '%s' from remote machine: %w", remotePubKeyPath, err)
	}

	slog.Debug("Copying public SSH key to remote machine", "path", remotePubKeyPath)

	if err := k.sshProvider.CopyToNode(publicKeyPath, remotePubKeyPath); err != nil {
		return fmt.Errorf("failed to copy public SSH key to remote machine: %w", err)
	}

	deleteObsoletePubKeyFromAuthKeys := fmt.Sprintf("sudo sed -i '/.*%s.*/d' %s", publicKeyComment, authorizedKeysPath)
	addNewPubKeyToAuthKeys := fmt.Sprintf("sudo cat %s >> %s", remotePubKeyPath, authorizedKeysPath)
	removePubKeyFile := "rm -f " + remotePubKeyPath

	authorizeRemotePubKeyCmd := deleteObsoletePubKeyFromAuthKeys + " && " +
		addNewPubKeyToAuthKeys + " && " +
		removePubKeyFile

	slog.Debug("Adding public SSH key to authorized keys file on remote machine")
	if err := k.sshProvider.Exec(authorizeRemotePubKeyCmd); err != nil {
		return fmt.Errorf("failed to add public SSH key to authorized keys file: %w", err)
	}

	slog.Debug("Public SSH key authorized on remote machine", "path", publicKeyPath, "comment", publicKeyComment)
	return nil
}
