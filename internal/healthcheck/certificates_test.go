// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package healthcheck_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/healthcheck"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var now = time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC)

func newCertificate(notAfter time.Time) (*x509.Certificate, string) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	Expect(err).ToNot(HaveOccurred())

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test"},
		NotBefore:    notAfter.AddDate(-1, 0, 0),
		NotAfter:     notAfter,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	Expect(err).ToNot(HaveOccurred())

	certificate, err := x509.ParseCertificate(der)
	Expect(err).ToNot(HaveOccurred())

	pemData := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	return certificate, base64.StdEncoding.EncodeToString(pemData)
}

func writeKubeconfig(dir, clusterName, server, caData, clientData string) string {
	content := fmt.Sprintf(`apiVersion: v1
kind: Config
clusters:
- name: other
  cluster:
    server: https://10.0.0.1:6443
- name: %[1]s
  cluster:
    certificate-authority-data: %[3]s
    server: %[2]s
users:
- name: other-user
  user: {}
- name: admin@%[1]s
  user:
    client-certificate-data: %[4]s
    client-key-data: a2V5
contexts:
- name: other
  context:
    cluster: other
    user: other-user
- name: admin@%[1]s
  context:
    cluster: %[1]s
    user: admin@%[1]s
current-context: other
`, clusterName, server, caData, clientData)

	path := filepath.Join(dir, "config")
	Expect(os.WriteFile(path, []byte(content), 0o600)).To(Succeed())
	return path
}

func peerCertificates(chain ...*x509.Certificate) healthcheck.PeerCertificatesFunc {
	return func(string) ([]*x509.Certificate, error) {
		return chain, nil
	}
}

var _ = Describe("certificates check", func() {
	var dir string

	BeforeEach(func() {
		dir = GinkgoT().TempDir()
	})

	newCheck := func(kubeconfigPath, clusterName string, peerFunc healthcheck.PeerCertificatesFunc) healthcheck.Check {
		return healthcheck.NewCertificatesCheck(healthcheck.CertificatesCheckConfig{
			KubeconfigPath:       kubeconfigPath,
			ClusterName:          clusterName,
			PeerCertificatesFunc: peerFunc,
			Now:                  func() time.Time { return now },
		})
	}

	It("passes and names the certificate that expires first", func() {
		_, ca := newCertificate(now.AddDate(10, 0, 0))
		_, client := newCertificate(now.AddDate(0, 6, 0))
		server, _ := newCertificate(now.AddDate(0, 3, 0))
		path := writeKubeconfig(dir, "k2s-cluster", "https://172.19.1.100:6443", ca, client)

		var dialedAddress string
		check := newCheck(path, "k2s-cluster", func(address string) ([]*x509.Certificate, error) {
			dialedAddress = address
			return []*x509.Certificate{server}, nil
		})

		result := runSingle(check)

		Expect(dialedAddress).To(Equal("172.19.1.100:6443"))
		Expect(result.Name).To(Equal("cluster-certificates"))
		Expect(result.Status).To(Equal(healthcheck.StatusPass))
		Expect(result.Message).To(Equal("3 certificate(s) valid, API server certificate expires first on 2026-09-01"))
		Expect(result.Hint).To(BeEmpty())
	})

	It("warns when a certificate expires within 30 days", func() {
		_, ca := newCertificate(now.AddDate(10, 0, 0))
		_, client := newCertificate(now.AddDate(0, 0, 10))
		server, _ := newCertificate(now.AddDate(1, 0, 0))
		path := writeKubeconfig(dir, "k2s-cluster", "https://172.19.1.100:6443", ca, client)

		result := runSingle(newCheck(path, "k2s-cluster", peerCertificates(server)))

		Expect(result.Status).To(Equal(healthcheck.StatusWarn))
		Expect(result.Message).To(Equal("client certificate expires on 2026-06-11"))
		Expect(result.Hint).To(ContainSubstring("k2s system certificate renew --force"))
	})

	It("fails when a certificate is expired", func() {
		_, ca := newCertificate(now.AddDate(10, 0, 0))
		_, client := newCertificate(now.AddDate(0, 0, 10))
		server, _ := newCertificate(now.AddDate(0, 0, -1))
		path := writeKubeconfig(dir, "k2s-cluster", "https://172.19.1.100:6443", ca, client)

		result := runSingle(newCheck(path, "k2s-cluster", peerCertificates(server)))

		Expect(result.Status).To(Equal(healthcheck.StatusFail))
		Expect(result.Message).To(Equal("API server certificate expired on 2026-05-31; client certificate expires on 2026-06-11"))
		Expect(result.Hint).To(ContainSubstring("k2s system certificate renew --force"))
	})

	It("treats a certificate expiring exactly now as expired", func() {
		_, ca := newCertificate(now)
		path := writeKubeconfig(dir, "k2s-cluster", "https://172.19.1.100:6443", ca, "")

		result := runSingle(newCheck(path, "k2s-cluster", peerCertificates()))

		Expect(result.Status).To(Equal(healthcheck.StatusFail))
	})

	It("evaluates the kubeconfig certificates when the API server is not reachable", func() {
		_, ca := newCertificate(now.AddDate(10, 0, 0))
		_, client := newCertificate(now.AddDate(1, 0, 0))
		path := writeKubeconfig(dir, "k2s-cluster", "https://172.19.1.100:6443", ca, client)

		result := runSingle(newCheck(path, "k2s-cluster", func(string) ([]*x509.Certificate, error) {
			return nil, errors.New("connection refused")
		}))

		Expect(result.Status).To(Equal(healthcheck.StatusPass))
		Expect(result.Message).To(Equal("2 certificate(s) valid, client certificate expires first on 2027-06-01; " +
			"API server certificate not checked: could not connect to '172.19.1.100:6443': connection refused"))
	})

	It("uses port 443 when the server URL has no port", func() {
		_, ca := newCertificate(now.AddDate(10, 0, 0))
		path := writeKubeconfig(dir, "k2s-cluster", "https://my-cluster", ca, "")

		var dialedAddress string
		runSingle(newCheck(path, "k2s-cluster", func(address string) ([]*x509.Certificate, error) {
			dialedAddress = address
			return nil, errors.New("unreachable")
		}))

		Expect(dialedAddress).To(Equal("my-cluster:443"))
	})

	It("does not connect to non-HTTPS servers", func() {
		_, ca := newCertificate(now.AddDate(10, 0, 0))
		path := writeKubeconfig(dir, "k2s-cluster", "http://172.19.1.100:8080", ca, "")

		result := runSingle(newCheck(path, "k2s-cluster", func(string) ([]*x509.Certificate, error) {
			Fail("must not connect")
			return nil, nil
		}))

		Expect(result.Status).To(Equal(healthcheck.StatusPass))
		Expect(result.Message).To(ContainSubstring("is not an HTTPS URL"))
	})

	It("falls back to the legacy cluster name", func() {
		_, ca := newCertificate(now.AddDate(10, 0, 0))
		path := writeKubeconfig(dir, "kubernetes", "https://172.19.1.100:6443", ca, "")

		result := runSingle(newCheck(path, "k2s-cluster", peerCertificates()))

		Expect(result.Status).To(Equal(healthcheck.StatusPass))
		Expect(result.Message).To(HavePrefix("1 certificate(s) valid, cluster CA certificate"))
	})

	It("skips when the cluster is not in the kubeconfig", func() {
		_, ca := newCertificate(now.AddDate(10, 0, 0))
		path := writeKubeconfig(dir, "some-cluster", "https://172.19.1.100:6443", ca, "")

		result := runSingle(newCheck(path, "k2s-cluster", peerCertificates()))

		Expect(result.Status).To(Equal(healthcheck.StatusSkip))
		Expect(result.Message).To(ContainSubstring("k2s-cluster"))
	})

	It("skips when the kubeconfig does not exist", func() {
		result := runSingle(newCheck(filepath.Join(dir, "missing"), "k2s-cluster", peerCertificates()))

		Expect(result.Status).To(Equal(healthcheck.StatusSkip))
		Expect(result.Message).To(ContainSubstring("could not read kubeconfig"))
	})

	It("skips when no certificate could be read", func() {
		path := writeKubeconfig(dir, "k2s-cluster", "https://172.19.1.100:6443", "", "")

		result := runSingle(newCheck(path, "k2s-cluster", func(string) ([]*x509.Certificate, error) {
			return nil, errors.New("connection refused")
		}))

		Expect(result.Status).To(Equal(healthcheck.StatusSkip))
		Expect(result.Message).To(HavePrefix("no certificates found; API server certificate not checked"))
	})

	It("evaluates every certificate of a bundle", func() {
		_, ca := newCertificate(now.AddDate(10, 0, 0))
		_, leaf := newCertificate(now.AddDate(1, 0, 0))
		_, intermediate := newCertificate(now.AddDate(0, 0, -1))
		leafPem, err := base64.StdEncoding.DecodeString(leaf)
		Expect(err).ToNot(HaveOccurred())
		intermediatePem, err := base64.StdEncoding.DecodeString(intermediate)
		Expect(err).ToNot(HaveOccurred())
		bundle := base64.StdEncoding.EncodeToString(append(leafPem, intermediatePem...))
		path := writeKubeconfig(dir, "k2s-cluster", "https://172.19.1.100:6443", ca, bundle)

		result := runSingle(newCheck(path, "k2s-cluster", peerCertificates()))

		Expect(result.Status).To(Equal(healthcheck.StatusFail))
		Expect(result.Message).To(ContainSubstring("client certificate (2 of 2 in bundle) expired on 2026-05-31"))
	})

	It("skips when the kubeconfig is empty", func() {
		path := filepath.Join(dir, "config")
		Expect(os.WriteFile(path, []byte("# nothing here\n"), 0o600)).To(Succeed())

		result := runSingle(newCheck(path, "k2s-cluster", peerCertificates()))

		Expect(result.Status).To(Equal(healthcheck.StatusSkip))
	})

	It("fails when a certificate in the kubeconfig is malformed", func() {
		path := writeKubeconfig(dir, "k2s-cluster", "https://172.19.1.100:6443", base64.StdEncoding.EncodeToString([]byte("garbage")), "")

		result := runSingle(newCheck(path, "k2s-cluster", peerCertificates()))

		Expect(result.Status).To(Equal(healthcheck.StatusFail))
		Expect(result.Message).To(ContainSubstring("could not parse cluster CA certificate"))
	})
})

var _ = Describe("GetPeerCertificates", func() {
	It("returns the certificate presented by a TLS server", func() {
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
		DeferCleanup(server.Close)

		chain, err := healthcheck.GetPeerCertificates(strings.TrimPrefix(server.URL, "https://"))

		Expect(err).ToNot(HaveOccurred())
		Expect(chain).ToNot(BeEmpty())
		Expect(chain[0].Equal(server.Certificate())).To(BeTrue())
	})

	It("returns an error when nothing listens on the address", func() {
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
		address := strings.TrimPrefix(server.URL, "https://")
		server.Close()

		_, err := healthcheck.GetPeerCertificates(address)

		Expect(err).To(HaveOccurred())
	})
})
