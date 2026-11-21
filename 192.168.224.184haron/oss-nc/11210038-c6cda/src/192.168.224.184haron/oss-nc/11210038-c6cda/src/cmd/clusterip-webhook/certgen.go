// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"log/slog"
	"math/big"
	mathrand "math/rand"
	"os"
	"path/filepath"
	"time"

	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const certValidityDuration = 365 * 24 * time.Hour // 1 year

// certGenConfig holds parameters for certificate generation and webhook patching.
type certGenConfig struct {
	CertPath    string
	KeyPath     string
	ServiceName string
	Namespace   string
	WebhookName string
}

// runCertGen generates a self-signed TLS certificate, writes it to disk,
// and patches the MutatingWebhookConfiguration caBundle. This is intended
// to run as an init container so that each Pod recreation produces a fresh
// certificate with a known validity period.
func runCertGen(cfg certGenConfig) error {
	slog.Info("Generating TLS certificate",
		"serviceName", cfg.ServiceName,
		"namespace", cfg.Namespace,
		"webhookName", cfg.WebhookName,
		"certPath", cfg.CertPath,
		"keyPath", cfg.KeyPath,
		"validity", certValidityDuration,
	)

	caKey, caPEM, err := generateCA(cfg.ServiceName)
	if err != nil {
		return fmt.Errorf("generate CA: %w", err)
	}

	caCert, err := x509.ParseCertificate(caKey.caCertDER)
	if err != nil {
		return fmt.Errorf("parse CA certificate: %w", err)
	}

	certPEM, keyPEM, err := generateServerCert(caCert, caKey.key, cfg.ServiceName, cfg.Namespace)
	if err != nil {
		return fmt.Errorf("generate server certificate: %w", err)
	}

	if err := writeCertFiles(cfg.CertPath, certPEM, cfg.KeyPath, keyPEM); err != nil {
		return err
	}

	if err := patchWebhookCABundle(cfg.WebhookName, caPEM); err != nil {
		return err
	}

	slog.Info("Certificate generation and webhook patching completed successfully")
	return nil
}

type caKeyPair struct {
	key       *ecdsa.PrivateKey
	caCertDER []byte
}

func generateCA(serviceName string) (*caKeyPair, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("generate CA key: %w", err)
	}

	serialNumber, err := cryptoRandSerial()
	if err != nil {
		return nil, nil, err
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber:          serialNumber,
		Subject:               pkix.Name{CommonName: serviceName + " CA"},
		NotBefore:             now.Add(-1 * time.Hour),
		NotAfter:              now.Add(certValidityDuration),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		IsCA:                  true,
		BasicConstraintsValid: true,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, fmt.Errorf("create CA certificate: %w", err)
	}

	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})

	return &caKeyPair{key: key, caCertDER: certDER}, caPEM, nil
}

func generateServerCert(caCert *x509.Certificate, caKey *ecdsa.PrivateKey, serviceName, namespace string) (certPEM, keyPEM []byte, err error) {
	serverKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("generate server key: %w", err)
	}

	serialNumber, err := cryptoRandSerial()
	if err != nil {
		return nil, nil, err
	}

	dnsNames := []string{
		serviceName,
		serviceName + "." + namespace,
		serviceName + "." + namespace + ".svc",
		serviceName + "." + namespace + ".svc.cluster.local",
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject:      pkix.Name{CommonName: serviceName},
		DNSNames:     dnsNames,
		NotBefore:    now.Add(-1 * time.Hour),
		NotAfter:     now.Add(certValidityDuration),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}

	serverCertDER, err := x509.CreateCertificate(rand.Reader, template, caCert, &serverKey.PublicKey, caKey)
	if err != nil {
		return nil, nil, fmt.Errorf("create server certificate: %w", err)
	}

	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: serverCertDER})

	serverKeyDER, err := x509.MarshalECPrivateKey(serverKey)
	if err != nil {
		return nil, nil, fmt.Errorf("marshal server key: %w", err)
	}
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: serverKeyDER})

	slog.Info("Server certificate generated", "dnsNames", dnsNames,
		"notBefore", template.NotBefore.Format(time.RFC3339),
		"notAfter", template.NotAfter.Format(time.RFC3339))

	return certPEM, keyPEM, nil
}

func writeCertFiles(certPath string, certPEM []byte, keyPath string, keyPEM []byte) error {
	for _, dir := range []string{filepath.Dir(certPath), filepath.Dir(keyPath)} {
		if dir != "" {
			if err := os.MkdirAll(dir, 0755); err != nil {
				return fmt.Errorf("create directory %q: %w", dir, err)
			}
		}
	}

	if err := os.WriteFile(certPath, certPEM, 0644); err != nil {
		return fmt.Errorf("write cert file %q: %w", certPath, err)
	}
	slog.Info("Certificate written", "path", certPath)

	if err := os.WriteFile(keyPath, keyPEM, 0600); err != nil {
		return fmt.Errorf("write key file %q: %w", keyPath, err)
	}
	slog.Info("Private key written", "path", keyPath)

	return nil
}

const maxConflictRetries = 5

func patchWebhookCABundle(webhookName string, caPEM []byte) error {
	config, err := rest.InClusterConfig()
	if err != nil {
		return fmt.Errorf("create in-cluster config: %w", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return fmt.Errorf("create kubernetes client: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Retry on conflict (409) to handle concurrent updates during rolling updates
	for attempt := 0; attempt < maxConflictRetries; attempt++ {
		webhookCfg, err := clientset.AdmissionregistrationV1().MutatingWebhookConfigurations().Get(ctx, webhookName, metav1.GetOptions{})
		if err != nil {
			return fmt.Errorf("get MutatingWebhookConfiguration %q: %w", webhookName, err)
		}

		for i := range webhookCfg.Webhooks {
			webhookCfg.Webhooks[i].ClientConfig.CABundle = caPEM
		}

		_, err = clientset.AdmissionregistrationV1().MutatingWebhookConfigurations().Update(ctx, webhookCfg, metav1.UpdateOptions{})
		if err == nil {
			slog.Info("Webhook configuration patched", "webhookName", webhookName, "webhookCount", len(webhookCfg.Webhooks))
			return nil
		}
		if k8serrors.IsConflict(err) {
			slog.Info("Conflict updating webhook configuration, retrying", "attempt", attempt+1)
			// Backoff with jitter to avoid thundering-herd on concurrent pod starts
			backoff := time.Duration(attempt+1)*100*time.Millisecond + time.Duration(mathrand.Int63n(50))*time.Millisecond
			time.Sleep(backoff)
			continue
		}
		return fmt.Errorf("update MutatingWebhookConfiguration %q: %w", webhookName, err)
	}

	return fmt.Errorf("update MutatingWebhookConfiguration %q: exceeded %d conflict retries", webhookName, maxConflictRetries)
}

func cryptoRandSerial() (*big.Int, error) {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, fmt.Errorf("generate serial number: %w", err)
	}
	return serial, nil
}
