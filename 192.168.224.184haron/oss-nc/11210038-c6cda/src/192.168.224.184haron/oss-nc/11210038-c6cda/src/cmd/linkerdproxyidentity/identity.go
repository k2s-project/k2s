// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Linkerd's proxy reads these environment variables and expects key.p8 and
// csr.der in the identity directory before it starts. This mirrors the
// upstream proxy-identity bootstrap contract for Windows.
func bootstrapIdentity(identityDir, localName, trustAnchors string) error {
	if strings.TrimSpace(identityDir) == "" {
		return errors.New("LINKERD2_PROXY_IDENTITY_DIR is required")
	}
	if strings.TrimSpace(localName) == "" {
		return errors.New("LINKERD2_PROXY_IDENTITY_LOCAL_NAME is required")
	}
	if err := validateTrustAnchors(trustAnchors); err != nil {
		return err
	}

	identityInfo, err := os.Stat(identityDir)
	if err != nil {
		return fmt.Errorf("inspect identity directory %q: %w", identityDir, err)
	}
	if !identityInfo.IsDir() {
		return fmt.Errorf("identity path %q is not a directory", identityDir)
	}
	keyPath := filepath.Join(identityDir, "key.p8")
	csrPath := filepath.Join(identityDir, "csr.der")
	keyInfo, keyErr := os.Stat(keyPath)
	csrInfo, csrErr := os.Stat(csrPath)
	keyExists := keyErr == nil
	csrExists := csrErr == nil
	if keyErr != nil && !errors.Is(keyErr, os.ErrNotExist) {
		return fmt.Errorf("inspect identity key: %w", keyErr)
	}
	if csrErr != nil && !errors.Is(csrErr, os.ErrNotExist) {
		return fmt.Errorf("inspect identity CSR: %w", csrErr)
	}
	if keyExists != csrExists {
		// A crash between the two renames can leave one canonical file behind.
		if err := removeIdentityFile(keyPath); err != nil {
			return fmt.Errorf("remove partial identity key: %w", err)
		}
		if err := removeIdentityFile(csrPath); err != nil {
			return fmt.Errorf("remove partial identity CSR: %w", err)
		}
		keyExists = false
		csrExists = false
	}
	if keyExists {
		if !keyInfo.Mode().IsRegular() || !csrInfo.Mode().IsRegular() {
			return errors.New("identity key and CSR must be regular files")
		}
		return validateExistingIdentity(keyPath, csrPath, localName)
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generate ECDSA identity key: %w", err)
	}
	keyBytes, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return fmt.Errorf("marshal identity key as PKCS#8: %w", err)
	}

	requestBytes, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject:  pkix.Name{CommonName: localName},
		DNSNames: []string{localName},
	}, key)
	if err != nil {
		return fmt.Errorf("create identity CSR: %w", err)
	}

	keyTempPath, err := writeIdentityTempFile(identityDir, "key.p8", keyBytes)
	if err != nil {
		return fmt.Errorf("write identity key: %w", err)
	}
	csrTempPath, err := writeIdentityTempFile(identityDir, "csr.der", requestBytes)
	if err != nil {
		_ = os.Remove(keyTempPath)
		return fmt.Errorf("write identity CSR: %w", err)
	}
	cleanup := func() {
		_ = os.Remove(keyTempPath)
		_ = os.Remove(csrTempPath)
	}
	if err := os.Rename(keyTempPath, keyPath); err != nil {
		cleanup()
		return fmt.Errorf("install identity key: %w", err)
	}
	if err := os.Rename(csrTempPath, csrPath); err != nil {
		_ = os.Remove(keyPath)
		cleanup()
		return fmt.Errorf("install identity CSR: %w", err)
	}
	return nil
}

func removeIdentityFile(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func writeIdentityTempFile(identityDir, name string, data []byte) (string, error) {
	tempFile, err := os.CreateTemp(identityDir, "."+name+"-*.tmp")
	if err != nil {
		return "", err
	}
	tempPath := tempFile.Name()
	if err := tempFile.Chmod(0o600); err != nil {
		_ = tempFile.Close()
		_ = os.Remove(tempPath)
		return "", err
	}
	if _, err := tempFile.Write(data); err != nil {
		_ = tempFile.Close()
		_ = os.Remove(tempPath)
		return "", err
	}
	if err := tempFile.Close(); err != nil {
		_ = os.Remove(tempPath)
		return "", err
	}
	return tempPath, nil
}

func validateExistingIdentity(keyPath, csrPath, localName string) error {
	keyBytes, err := os.ReadFile(keyPath)
	if err != nil {
		return fmt.Errorf("read identity key: %w", err)
	}
	privateKey, err := x509.ParsePKCS8PrivateKey(keyBytes)
	if err != nil {
		return fmt.Errorf("parse identity key as PKCS#8 DER: %w", err)
	}
	signer, ok := privateKey.(crypto.Signer)
	if !ok {
		return errors.New("identity key does not expose a public key")
	}

	csrBytes, err := os.ReadFile(csrPath)
	if err != nil {
		return fmt.Errorf("read identity CSR: %w", err)
	}
	csr, err := x509.ParseCertificateRequest(csrBytes)
	if err != nil {
		return fmt.Errorf("parse identity CSR: %w", err)
	}
	if err := csr.CheckSignature(); err != nil {
		return fmt.Errorf("verify identity CSR signature: %w", err)
	}
	if !publicKeysEqual(signer.Public(), csr.PublicKey) {
		return errors.New("identity key does not match CSR public key")
	}
	if csr.Subject.CommonName != "" && csr.Subject.CommonName != localName {
		return fmt.Errorf("identity CSR common name %q does not match local name %q", csr.Subject.CommonName, localName)
	}
	if len(csr.DNSNames) > 0 {
		matchesLocalName := false
		for _, name := range csr.DNSNames {
			if name == localName {
				matchesLocalName = true
				break
			}
		}
		if !matchesLocalName {
			return fmt.Errorf("identity CSR DNS names %v do not contain local name %q", csr.DNSNames, localName)
		}
	}
	if csr.Subject.CommonName == "" && len(csr.DNSNames) == 0 {
		return errors.New("identity CSR has no common name or DNS names to validate")
	}
	return nil
}

func publicKeysEqual(left, right interface{}) bool {
	leftDER, leftErr := x509.MarshalPKIXPublicKey(left)
	rightDER, rightErr := x509.MarshalPKIXPublicKey(right)
	return leftErr == nil && rightErr == nil && string(leftDER) == string(rightDER)
}

func validateTrustAnchors(value string) error {
	if strings.TrimSpace(value) == "" {
		return errors.New("LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS is required")
	}

	remaining := []byte(value)
	certificateCount := 0
	for len(strings.TrimSpace(string(remaining))) > 0 {
		block, rest := pem.Decode(remaining)
		if block == nil {
			return errors.New("LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS contains invalid PEM")
		}
		if block.Type != "CERTIFICATE" {
			return fmt.Errorf("LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS contains PEM block %q, expected CERTIFICATE", block.Type)
		}
		if _, err := x509.ParseCertificate(block.Bytes); err != nil {
			return fmt.Errorf("parse trust-anchor certificate: %w", err)
		}
		certificateCount++
		remaining = rest
	}
	if certificateCount == 0 {
		return errors.New("LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS contains no certificates")
	}
	return nil
}
