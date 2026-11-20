// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package ssh

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/pem"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"

	"golang.org/x/crypto/ssh"
)

func CreateKeyPair(privateKeyPath, publicKeyComment string) (publicKeyPath string, err error) {
	slog.Debug("Creating SSH key pair", "private-key-path", privateKeyPath, "comment", publicKeyComment)

	keyDir := filepath.Dir(privateKeyPath)
	if err := os.MkdirAll(keyDir, os.ModePerm); err != nil {
		return "", fmt.Errorf("failed to create SSH key pair directory '%s': %w", keyDir, err)
	}

	privatekey, err := ecdsa.GenerateKey(elliptic.P521(), rand.Reader)
	if err != nil {
		return "", fmt.Errorf("failed to generate private SSH key: %w", err)
	}

	pemBlock, err := ssh.MarshalPrivateKey(privatekey, "created-by-K2s")
	if err != nil {
		return "", fmt.Errorf("failed to marshal private SSH key: %w", err)
	}

	privateKeyFile, err := os.Create(privateKeyPath)
	if err != nil {
		return "", fmt.Errorf("failed to create private SSH key file '%s': %w", privateKeyPath, err)
	}
	defer func() {
		if err := privateKeyFile.Close(); err != nil {
			slog.Error("failed to close private SSH key file", "path", privateKeyPath, "error", err)
		}
	}()

	err = pem.Encode(privateKeyFile, pemBlock)
	if err != nil {
		return "", fmt.Errorf("failed to PEM encode private SSH key: %w", err)
	}

	publicKey, err := ssh.NewPublicKey(&privatekey.PublicKey)
	if err != nil {
		return "", fmt.Errorf("failed to create public SSH key: %w", err)

	}

	publicKeyBytes := ssh.MarshalAuthorizedKey(publicKey)

	if publicKeyComment != "" {
		publicKeyBytes = append(publicKeyBytes[:len(publicKeyBytes)-1], []byte(" "+publicKeyComment+"\n")...)
	}

	publicKeyPath = privateKeyPath + ".pub"

	if err := os.WriteFile(publicKeyPath, publicKeyBytes, fs.ModePerm); err != nil {
		return "", fmt.Errorf("failed to write public SSH key to file: %w", err)
	}

	slog.Debug("SSH key pair created", "private-key-path", privateKeyPath, "public-key-path", publicKeyPath)
	return publicKeyPath, nil
}
