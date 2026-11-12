// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package healthcheck

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
)

const (
	// CertificateExpiryWarningPeriod is the remaining validity below which the certificate check warns.
	CertificateExpiryWarningPeriod = 30 * 24 * time.Hour

	apiServerDialTimeout = 5 * time.Second
	certificateDateFmt   = "2006-01-02"
	certificateHint      = "Renew the certificates with 'k2s system certificate renew --force'"
)

// PeerCertificatesFunc returns the certificate chain presented by the TLS server at the given address (host:port).
type PeerCertificatesFunc func(address string) ([]*x509.Certificate, error)

// CertificatesCheckConfig holds the inputs for the cluster certificates check.
type CertificatesCheckConfig struct {
	// KubeconfigPath is the path to the kubeconfig file containing the K2s cluster context.
	KubeconfigPath string
	// ClusterName is the name of the K2s cluster in the kubeconfig.
	ClusterName string
	// PeerCertificatesFunc retrieves the API server certificate; defaults to a TLS handshake.
	PeerCertificatesFunc PeerCertificatesFunc
	// Now returns the current time; defaults to time.Now.
	Now func() time.Time
}

type namedCertificate struct {
	name        string
	certificate *x509.Certificate
}

// NewCertificatesCheck returns a check that verifies that the cluster CA, the client certificate
// in the kubeconfig and the certificate served by the API server are neither expired nor about to expire.
func NewCertificatesCheck(config CertificatesCheckConfig) Check {
	if config.PeerCertificatesFunc == nil {
		config.PeerCertificatesFunc = GetPeerCertificates
	}
	if config.Now == nil {
		config.Now = time.Now
	}

	return Check{
		Name:        "cluster-certificates",
		Description: "Cluster certificates are valid",
		Run: func() Outcome {
			return checkCertificates(config)
		},
	}
}

// GetPeerCertificates performs a TLS handshake with the given address and returns the presented certificate chain.
func GetPeerCertificates(address string) ([]*x509.Certificate, error) {
	dialer := &net.Dialer{Timeout: apiServerDialTimeout}
	// Verification is skipped on purpose: only the validity period of the presented certificate is read,
	// which must also work when the certificate is already expired. No data is sent over the connection.
	conn, err := tls.DialWithDialer(dialer, "tcp", address, &tls.Config{InsecureSkipVerify: true}) //nolint:gosec
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	return conn.ConnectionState().PeerCertificates, nil
}

func checkCertificates(config CertificatesCheckConfig) Outcome {
	kubeConfig, err := kubeconfig.FromFile(config.KubeconfigPath)
	if err != nil {
		return skip(err.Error())
	}

	if kubeConfig == nil {
		return skip(fmt.Sprintf("kubeconfig '%s' is empty", config.KubeconfigPath))
	}

	cluster, user, err := findClusterCredentials(kubeConfig, config.ClusterName)
	if err != nil {
		return skip(err.Error())
	}

	var certificates []namedCertificate
	var notes []string

	for _, source := range []struct{ name, data string }{
		{"cluster CA certificate", cluster.Details.Cert},
		{"client certificate", user.Details.Cert},
	} {
		if source.data == "" {
			continue
		}
		parsed, err := parseBase64PemCertificates(source.data)
		if err != nil {
			return fail(fmt.Sprintf("could not parse %s in '%s': %v", source.name, config.KubeconfigPath, err), "Check the kubeconfig file or reinstall K2s")
		}
		for i, certificate := range parsed {
			name := source.name
			if len(parsed) > 1 {
				name = fmt.Sprintf("%s (%d of %d in bundle)", source.name, i+1, len(parsed))
			}
			certificates = append(certificates, namedCertificate{name: name, certificate: certificate})
		}
	}

	apiServerCertificate, err := getApiServerCertificate(cluster.Details.Server, config.PeerCertificatesFunc)
	if err != nil {
		notes = append(notes, fmt.Sprintf("API server certificate not checked: %v", err))
	} else {
		certificates = append(certificates, namedCertificate{name: "API server certificate", certificate: apiServerCertificate})
	}

	if len(certificates) == 0 {
		return skip(joinMessages(append([]string{"no certificates found"}, notes...)))
	}

	return evaluateCertificates(certificates, notes, config.Now())
}

func findClusterCredentials(kubeConfig *kubeconfig.Kubeconfig, clusterName string) (*kubeconfig.Cluster, *kubeconfig.User, error) {
	context, err := kubeConfig.FindContextByCluster(clusterName)
	if err != nil && clusterName != definitions.LegacyClusterName {
		if legacyContext, legacyErr := kubeConfig.FindContextByCluster(definitions.LegacyClusterName); legacyErr == nil {
			context, err = legacyContext, nil
		}
	}
	if err != nil {
		return nil, nil, err
	}
	return kubeConfig.FindK8sApiCredentials(context.Name)
}

func getApiServerCertificate(server string, peerCertificatesFunc PeerCertificatesFunc) (*x509.Certificate, error) {
	serverUrl, err := url.Parse(server)
	if err != nil {
		return nil, fmt.Errorf("invalid server URL '%s': %w", server, err)
	}
	if serverUrl.Scheme != "https" || serverUrl.Hostname() == "" {
		return nil, fmt.Errorf("server URL '%s' is not an HTTPS URL", server)
	}

	port := serverUrl.Port()
	if port == "" {
		port = "443"
	}

	chain, err := peerCertificatesFunc(net.JoinHostPort(serverUrl.Hostname(), port))
	if err != nil {
		return nil, fmt.Errorf("could not connect to '%s': %w", serverUrl.Host, err)
	}
	if len(chain) == 0 {
		return nil, fmt.Errorf("'%s' presented no certificate", serverUrl.Host)
	}
	return chain[0], nil
}

// parseBase64PemCertificates returns all certificates of a base64 encoded PEM bundle.
func parseBase64PemCertificates(data string) ([]*x509.Certificate, error) {
	pemBytes, err := base64.StdEncoding.DecodeString(data)
	if err != nil {
		return nil, fmt.Errorf("invalid base64 data: %w", err)
	}

	var certificates []*x509.Certificate
	for {
		var block *pem.Block
		block, pemBytes = pem.Decode(pemBytes)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, err
		}
		certificates = append(certificates, certificate)
	}
	if len(certificates) == 0 {
		return nil, errors.New("no PEM encoded certificate found")
	}
	return certificates, nil
}

func evaluateCertificates(certificates []namedCertificate, notes []string, now time.Time) Outcome {
	var expired, expiring []string
	earliest := certificates[0]

	for _, current := range certificates {
		notAfter := current.certificate.NotAfter
		if notAfter.Before(earliest.certificate.NotAfter) {
			earliest = current
		}

		switch {
		case !now.Before(notAfter):
			expired = append(expired, fmt.Sprintf("%s expired on %s", current.name, notAfter.Format(certificateDateFmt)))
		case notAfter.Sub(now) < CertificateExpiryWarningPeriod:
			expiring = append(expiring, fmt.Sprintf("%s expires on %s", current.name, notAfter.Format(certificateDateFmt)))
		}
	}

	switch {
	case len(expired) > 0:
		return fail(joinMessages(append(append(expired, expiring...), notes...)), certificateHint)
	case len(expiring) > 0:
		return warn(joinMessages(append(expiring, notes...)), certificateHint)
	default:
		message := fmt.Sprintf("%d certificate(s) valid, %s expires first on %s",
			len(certificates), earliest.name, earliest.certificate.NotAfter.Format(certificateDateFmt))
		return pass(joinMessages(append([]string{message}, notes...)))
	}
}

func joinMessages(messages []string) string {
	return strings.Join(messages, "; ")
}
