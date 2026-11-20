// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"io"
	"log"
	"maps"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	admissionv1 "k8s.io/api/admission/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
)

const (
	// webhookHost is the name under which the kube-apiserver calls the webhook. It
	// verifies the serving certificate against this name and selects its client
	// certificate by it.
	webhookHost = "clusterip-webhook.k2s-webhook.svc"

	// webhookArgsEnv passes the arguments of the webhook to TestWebhookProcess.
	webhookArgsEnv = "K2S_CLUSTERIP_WEBHOOK_TEST_ARGS"

	noClientCertificate  = "no client certificate"
	apiServerClient      = "client certificate of the kube-apiserver"
	untrustedClient      = "certificate of an untrusted CA"
	expiredClient        = "expired certificate"
	notYetValidClient    = "certificate that is not yet valid"
	serverAuthOnlyClient = "certificate for server authentication only"
	servingCertificate   = "serving certificate of the webhook"
	servingCAClient      = "client certificate of the webhook serving CA"
)

var _ = Describe("client CA file", func() {
	DescribeTable("is refused",
		func(content func() []byte, reason string) {
			path := filepath.Join(GinkgoT().TempDir(), "ca.crt")
			Expect(os.WriteFile(path, content(), 0o600)).To(Succeed())

			clientCAs, err := loadClientCAs(path)

			Expect(err).To(MatchError(ContainSubstring(reason)))
			Expect(clientCAs).To(BeNil())
		},
		Entry("when it is empty", func() []byte { return nil }, "contains no certificate"),
		Entry("when it is not PEM encoded", func() []byte { return []byte("not a certificate") }, "contains no certificate"),
		Entry("when a certificate is damaged", func() []byte {
			return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: []byte("damaged")})
		}, "parse certificate"),
		Entry("when it contains a private key", func() []byte {
			ca := newTestCA(nil)
			key, err := x509.MarshalECPrivateKey(ca.key)
			Expect(err).NotTo(HaveOccurred())
			return append(certificatePEM(ca.certificate), pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: key})...)
		}, `contains a "EC PRIVATE KEY" block`),
		Entry("when it contains a certificate that is not a CA", func() []byte {
			return certificatePEM(newTestCA(nil).issue(nil).Leaf)
		}, "is not a CA certificate"),
		Entry("when the CA certificate has expired", func() []byte {
			return certificatePEM(newTestCA(func(ca *x509.Certificate) {
				ca.NotBefore, ca.NotAfter = time.Now().Add(-2*time.Hour), time.Now().Add(-time.Hour)
			}).certificate)
		}, "is only valid from"),
		Entry("when the CA certificate is not yet valid", func() []byte {
			return certificatePEM(newTestCA(func(ca *x509.Certificate) {
				ca.NotBefore, ca.NotAfter = time.Now().Add(time.Hour), time.Now().Add(2*time.Hour)
			}).certificate)
		}, "is only valid from"),
	)

	It("is refused when it is missing", func() {
		clientCAs, err := loadClientCAs(filepath.Join(GinkgoT().TempDir(), "ca.crt"))

		Expect(err).To(MatchError(os.ErrNotExist))
		Expect(clientCAs).To(BeNil())
	})

	It("is required to create the admission server", func() {
		server, err := newAdmissionServer("", &WebhookHandler{}, tls.Certificate{}, nil)

		Expect(err).To(MatchError(ContainSubstring("client CA pool is required")))
		Expect(server).To(BeNil())
	})
})

var _ = Describe("admission server", func() {
	var fixture *admissionFixture

	BeforeEach(func() {
		fixture = newAdmissionFixture()
	})

	DescribeTable("rejects a caller that is not the kube-apiserver before a handler runs",
		func(client, alert string) {
			config := fixture.clientConfig(client)

			Expect(fixture.handshake(config)).To(MatchError(ContainSubstring("remote error: tls: " + alert)))
			for endpoint, review := range admissionRequests() {
				_, err := fixture.post(config, endpoint, review)
				Expect(err).To(HaveOccurred(), "%s answered a caller without a valid client certificate", endpoint)
			}

			Expect(fixture.clientset.Actions()).To(BeEmpty())
			Expect(fixture.cachedWorkloads()).To(BeEmpty())
			Expect(fixture.reservations()).To(BeEmpty())
		},
		Entry("without a client certificate", noClientCertificate, "certificate required"),
		Entry("with a certificate of an untrusted CA", untrustedClient, "unknown certificate authority"),
		Entry("with an expired certificate", expiredClient, "expired certificate"),
		Entry("with a certificate that is not yet valid", notYetValidClient, "expired certificate"),
		Entry("with a certificate for server authentication only", serverAuthOnlyClient, "bad certificate"),
		Entry("with the serving certificate of the webhook", servingCertificate, "unknown certificate authority"),
		Entry("with a client certificate of the webhook serving CA", servingCAClient, "unknown certificate authority"),
	)

	It("requires the client certificate from TLS 1.2 clients as well", func() {
		config := fixture.clientConfig(noClientCertificate)
		config.MaxVersion = tls.VersionTLS12

		Expect(fixture.handshake(config)).To(MatchError(ContainSubstring("remote error: tls: handshake failure")))
		Expect(fixture.clientset.Actions()).To(BeEmpty())
	})

	It("serves both admission endpoints to the client certificate of the kube-apiserver", func() {
		config := fixture.clientConfig(apiServerClient)

		service, err := fixture.post(config, "/mutate", serviceReview(false))
		Expect(err).NotTo(HaveOccurred())
		Expect(assignedClusterIP(service)).To(Equal("172.21.0.50"))
		Expect(fixture.reservations()).To(HaveKey("172.21.0.50"))

		workload, err := fixture.post(config, "/mutate-workload", workloadReview())
		Expect(err).NotTo(HaveOccurred())
		Expect(workload.Response.Allowed).To(BeTrue())
		Expect(fixture.changes()).To(Equal([]string{"delete services", "create services"}))
	})

	It("assigns an address to a dry-run Service without changing Services, the OS cache or the reservations", func() {
		fixture.handler.cache.Store("default", map[string]string{"app": "cached"}, "windows")
		fixture.reserve("172.21.0.50", time.Minute)
		fixture.reserve("172.21.0.51", -time.Minute)
		cachedWorkloads, reservations := fixture.cachedWorkloads(), fixture.reservations()
		config := fixture.clientConfig(apiServerClient)

		for range 2 {
			service, err := fixture.post(config, "/mutate", serviceReview(true))
			Expect(err).NotTo(HaveOccurred())
			Expect(assignedClusterIP(service)).To(Equal("172.21.0.52"))
		}

		Expect(fixture.changes()).To(BeEmpty())
		Expect(fixture.cachedWorkloads()).To(Equal(cachedWorkloads))
		Expect(fixture.reservations()).To(Equal(reservations))
	})
})

var _ = Describe("health server", func() {
	It("answers probes over plain HTTP and serves no admission endpoint", func() {
		server := newHealthServer("")
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		Expect(err).NotTo(HaveOccurred())
		go func() { _ = server.Serve(listener) }()
		DeferCleanup(server.Close)
		client := &http.Client{Timeout: 10 * time.Second}
		url := "http://" + listener.Addr().String()

		response, err := client.Get(url + "/healthz")
		Expect(err).NotTo(HaveOccurred())
		body, err := io.ReadAll(response.Body)
		Expect(err).NotTo(HaveOccurred())
		Expect(response.Body.Close()).To(Succeed())
		Expect(response.StatusCode).To(Equal(http.StatusOK))
		Expect(string(body)).To(Equal("ok"))

		for endpoint := range admissionRequests() {
			response, err := client.Post(url+endpoint, "application/json", strings.NewReader("{}"))
			Expect(err).NotTo(HaveOccurred())
			Expect(response.Body.Close()).To(Succeed())
			Expect(response.StatusCode).To(Equal(http.StatusNotFound), endpoint)
		}
	})
})

var _ = Describe("webhook start-up", func() {
	// Outside a cluster the webhook cannot get further than the creation of the
	// Kubernetes client, which is the step after the client CA is loaded.
	const nextStep = "Failed to create in-cluster config"

	It("fails when the client CA file is missing", func() {
		exitCode, output := runWebhook("--client-ca-file=" + filepath.Join(GinkgoT().TempDir(), "ca.crt"))

		Expect(exitCode).To(Equal(1), output)
		Expect(output).To(ContainSubstring("Failed to load client CA"))
		Expect(output).NotTo(ContainSubstring(nextStep))
	})

	It("fails when the client CA file holds no CA certificate", func() {
		path := filepath.Join(GinkgoT().TempDir(), "ca.crt")
		Expect(os.WriteFile(path, certificatePEM(newTestCA(nil).issue(nil).Leaf), 0o600)).To(Succeed())

		exitCode, output := runWebhook("--client-ca-file=" + path)

		Expect(exitCode).To(Equal(1), output)
		Expect(output).To(ContainSubstring("is not a CA certificate"))
		Expect(output).NotTo(ContainSubstring(nextStep))
	})

	It("continues with a valid client CA file", func() {
		path := filepath.Join(GinkgoT().TempDir(), "ca.crt")
		Expect(os.WriteFile(path, certificatePEM(newTestCA(nil).certificate), 0o600)).To(Succeed())

		exitCode, output := runWebhook("--client-ca-file=" + path)

		Expect(exitCode).To(Equal(1), output)
		Expect(output).NotTo(ContainSubstring("Failed to load client CA"))
		Expect(output).To(ContainSubstring(nextStep))
	})
})

// admissionFixture runs the admission server as main() creates it, in front of
// a fake cluster with a Service that a forged workload request would recreate.
type admissionFixture struct {
	addr      string
	handler   *WebhookHandler
	clientset *fake.Clientset
	serverCAs *x509.CertPool
	clients   map[string]*tls.Certificate
}

func newAdmissionFixture() *admissionFixture {
	GinkgoHelper()

	servingCAKey, servingCAPEM, err := generateCA("clusterip-webhook")
	Expect(err).NotTo(HaveOccurred())
	servingCA, err := x509.ParseCertificate(servingCAKey.caCertDER)
	Expect(err).NotTo(HaveOccurred())
	servingCertPEM, servingKeyPEM, err := generateServerCert(servingCA, servingCAKey.key, "clusterip-webhook", "k2s-webhook")
	Expect(err).NotTo(HaveOccurred())
	servingCert, err := tls.X509KeyPair(servingCertPEM, servingKeyPEM)
	Expect(err).NotTo(HaveOccurred())

	clientCA := newTestCA(nil)
	fixture := &admissionFixture{
		serverCAs: x509.NewCertPool(),
		clients: map[string]*tls.Certificate{
			apiServerClient: clientCA.issue(nil),
			untrustedClient: newTestCA(nil).issue(nil),
			expiredClient: clientCA.issue(func(client *x509.Certificate) {
				client.NotBefore, client.NotAfter = time.Now().Add(-2*time.Hour), time.Now().Add(-time.Hour)
			}),
			notYetValidClient: clientCA.issue(func(client *x509.Certificate) {
				client.NotBefore, client.NotAfter = time.Now().Add(time.Hour), time.Now().Add(2*time.Hour)
			}),
			serverAuthOnlyClient: clientCA.issue(func(client *x509.Certificate) {
				client.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
			}),
			servingCertificate: &servingCert,
			servingCAClient:    testCA{certificate: servingCA, key: servingCAKey.key}.issue(nil),
		},
	}
	Expect(fixture.serverCAs.AppendCertsFromPEM(servingCAPEM)).To(BeTrue())

	clientCAFile := filepath.Join(GinkgoT().TempDir(), "ca.crt")
	Expect(os.WriteFile(clientCAFile, certificatePEM(clientCA.certificate), 0o600)).To(Succeed())
	clientCAs, err := loadClientCAs(clientCAFile)
	Expect(err).NotTo(HaveOccurred())

	allocator, err := NewIPAllocator(defaultLinuxSubnet, defaultWindowsSubnet, defaultReservedIPs)
	Expect(err).NotTo(HaveOccurred())
	fixture.clientset = fake.NewSimpleClientset(&corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: "existing", Namespace: "default"},
		Spec: corev1.ServiceSpec{
			Selector:  map[string]string{"app": "existing"},
			ClusterIP: "172.21.0.55",
			Ports:     []corev1.ServicePort{{Port: 80, Protocol: corev1.ProtocolTCP}},
		},
	})
	fixture.handler = &WebhookHandler{clientset: fixture.clientset, allocator: allocator, cache: NewOSCache(cacheTTL)}

	server, err := newAdmissionServer("", fixture.handler, servingCert, clientCAs)
	Expect(err).NotTo(HaveOccurred())
	server.ErrorLog = log.New(GinkgoWriter, "", 0)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	Expect(err).NotTo(HaveOccurred())
	fixture.addr = listener.Addr().String()
	go func() { _ = server.ServeTLS(listener, "", "") }()
	DeferCleanup(server.Close)

	return fixture
}

// clientConfig returns the TLS configuration of a client that verifies the
// webhook like the kube-apiserver does. It presents its certificate regardless
// of the CAs the server announces, as an attacker would.
func (f *admissionFixture) clientConfig(client string) *tls.Config {
	config := &tls.Config{RootCAs: f.serverCAs, ServerName: webhookHost, MinVersion: tls.VersionTLS12}
	if certificate := f.clients[client]; certificate != nil {
		config.GetClientCertificate = func(*tls.CertificateRequestInfo) (*tls.Certificate, error) {
			return certificate, nil
		}
	}
	return config
}

// handshake connects without sending a request and returns the error with which
// the server ends the connection. A TLS 1.3 client learns that its certificate
// was rejected only when it reads.
func (f *admissionFixture) handshake(config *tls.Config) error {
	GinkgoHelper()

	connection, err := tls.DialWithDialer(&net.Dialer{Timeout: 10 * time.Second}, "tcp", f.addr, config)
	if err != nil {
		return err
	}
	defer connection.Close()

	Expect(connection.SetReadDeadline(time.Now().Add(10 * time.Second))).To(Succeed())
	_, err = connection.Read(make([]byte, 1))
	return err
}

// post sends an admission request and returns the answer of the handler.
func (f *admissionFixture) post(config *tls.Config, endpoint string, review *admissionv1.AdmissionReview) (*admissionv1.AdmissionReview, error) {
	GinkgoHelper()

	body, err := json.Marshal(review)
	Expect(err).NotTo(HaveOccurred())
	client := &http.Client{
		Transport: &http.Transport{TLSClientConfig: config, DisableKeepAlives: true},
		Timeout:   10 * time.Second,
	}

	response, err := client.Post("https://"+f.addr+endpoint, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	Expect(response.StatusCode).To(Equal(http.StatusOK), endpoint)

	answer := &admissionv1.AdmissionReview{}
	Expect(json.NewDecoder(response.Body).Decode(answer)).To(Succeed())
	Expect(answer.Response).NotTo(BeNil())
	return answer, nil
}

// reserve records an address as assigned to a Service that is being created.
func (f *admissionFixture) reserve(ip string, ttl time.Duration) {
	f.handler.allocator.mu.Lock()
	defer f.handler.allocator.mu.Unlock()
	f.handler.allocator.inFlight[ip] = time.Now().Add(ttl)
}

func (f *admissionFixture) reservations() map[string]time.Time {
	f.handler.allocator.mu.Lock()
	defer f.handler.allocator.mu.Unlock()
	return maps.Clone(f.handler.allocator.inFlight)
}

func (f *admissionFixture) cachedWorkloads() map[string]osCacheEntry {
	f.handler.cache.mu.RLock()
	defer f.handler.cache.mu.RUnlock()
	return maps.Clone(f.handler.cache.entries)
}

// changes returns the requests with which the handlers changed the cluster.
func (f *admissionFixture) changes() []string {
	var changes []string
	for _, action := range f.clientset.Actions() {
		if verb := action.GetVerb(); verb != "get" && verb != "list" && verb != "watch" {
			changes = append(changes, verb+" "+action.GetResource().Resource)
		}
	}
	return changes
}

// admissionRequests returns, for each admission endpoint, a request that
// changes state as soon as it reaches the handler.
func admissionRequests() map[string]*admissionv1.AdmissionReview {
	return map[string]*admissionv1.AdmissionReview{
		"/mutate":          serviceReview(false),
		"/mutate-workload": workloadReview(),
	}
}

// serviceReview is the admission request for a Service without a ClusterIP.
func serviceReview(dryRun bool) *admissionv1.AdmissionReview {
	return newReview("Service", dryRun, &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: "new", Namespace: "default"},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": "new"},
			Ports:    []corev1.ServicePort{{Port: 80, Protocol: corev1.ProtocolTCP}},
		},
	})
}

// workloadReview is the request that a forged call used to send: a Windows
// workload whose pod labels match the selector of an existing Service, which
// makes the handler delete and recreate that Service.
func workloadReview() *admissionv1.AdmissionReview {
	return newReview("Deployment", false, &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: "forged", Namespace: "default"},
		Spec: appsv1.DeploymentSpec{
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "existing"}},
				Spec:       corev1.PodSpec{NodeSelector: map[string]string{nodeOSKey: "windows"}},
			},
		},
	})
}

func newReview(kind string, dryRun bool, object any) *admissionv1.AdmissionReview {
	GinkgoHelper()

	raw, err := json.Marshal(object)
	Expect(err).NotTo(HaveOccurred())
	return &admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{APIVersion: "admission.k8s.io/v1", Kind: "AdmissionReview"},
		Request: &admissionv1.AdmissionRequest{
			UID:       "test",
			Kind:      metav1.GroupVersionKind{Kind: kind},
			Namespace: "default",
			Operation: admissionv1.Create,
			DryRun:    &dryRun,
			Object:    runtime.RawExtension{Raw: raw},
		},
	}
}

// assignedClusterIP returns the address that the answer to a Service request assigns.
func assignedClusterIP(review *admissionv1.AdmissionReview) string {
	GinkgoHelper()

	Expect(review.Response.Allowed).To(BeTrue())
	var patch []struct{ Path, Value string }
	Expect(json.Unmarshal(review.Response.Patch, &patch)).To(Succeed())
	Expect(patch).To(HaveLen(1))
	Expect(patch[0].Path).To(Equal("/spec/clusterIP"))
	return patch[0].Value
}

// testCA is a certificate authority that issues the certificates of the specs.
type testCA struct {
	certificate *x509.Certificate
	key         *ecdsa.PrivateKey
}

// newTestCA creates a self-signed CA certificate; modify adjusts it before signing.
func newTestCA(modify func(*x509.Certificate)) testCA {
	GinkgoHelper()

	template := &x509.Certificate{
		Subject:               pkix.Name{CommonName: "test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		IsCA:                  true,
		BasicConstraintsValid: true,
	}
	if modify != nil {
		modify(template)
	}
	key := newTestKey()
	return testCA{certificate: signCertificate(template, template, key, key), key: key}
}

// issue creates a client certificate of the CA; modify adjusts it before signing.
func (ca testCA) issue(modify func(*x509.Certificate)) *tls.Certificate {
	GinkgoHelper()

	template := &x509.Certificate{
		Subject:     pkix.Name{CommonName: "test client"},
		NotBefore:   time.Now().Add(-time.Hour),
		NotAfter:    time.Now().Add(time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	if modify != nil {
		modify(template)
	}
	key := newTestKey()
	certificate := signCertificate(template, ca.certificate, key, ca.key)
	return &tls.Certificate{Certificate: [][]byte{certificate.Raw}, PrivateKey: key, Leaf: certificate}
}

func newTestKey() *ecdsa.PrivateKey {
	GinkgoHelper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	Expect(err).NotTo(HaveOccurred())
	return key
}

func signCertificate(template, issuer *x509.Certificate, key, issuerKey *ecdsa.PrivateKey) *x509.Certificate {
	GinkgoHelper()

	serial, err := cryptoRandSerial()
	Expect(err).NotTo(HaveOccurred())
	template.SerialNumber = serial
	der, err := x509.CreateCertificate(rand.Reader, template, issuer, &key.PublicKey, issuerKey)
	Expect(err).NotTo(HaveOccurred())
	certificate, err := x509.ParseCertificate(der)
	Expect(err).NotTo(HaveOccurred())
	return certificate
}

func certificatePEM(certificate *x509.Certificate) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Raw})
}

// runWebhook starts main() with the given arguments in a child process and
// returns its exit code and output.
func runWebhook(args ...string) (int, string) {
	GinkgoHelper()

	encoded, err := json.Marshal(args)
	Expect(err).NotTo(HaveOccurred())
	executable, err := os.Executable()
	Expect(err).NotTo(HaveOccurred())
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	command := exec.CommandContext(ctx, executable, "-test.run=^TestWebhookProcess$")
	// Without the service host the webhook cannot mistake the test host for a cluster.
	command.Env = append(os.Environ(), webhookArgsEnv+"="+string(encoded), "KUBERNETES_SERVICE_HOST=")
	output, err := command.CombinedOutput()
	if exitError, isExit := errors.AsType[*exec.ExitError](err); isExit {
		return exitError.ExitCode(), string(output)
	}
	Expect(err).NotTo(HaveOccurred(), string(output))
	return 0, string(output)
}

// TestWebhookProcess is not a test. The start-up specs run this test binary
// again with the arguments of the webhook, and this function then enters main()
// so that the specs observe how the real process starts and exits.
func TestWebhookProcess(t *testing.T) {
	encoded, isChild := os.LookupEnv(webhookArgsEnv)
	if !isChild {
		t.Skip("runs only as the child process of the start-up specs")
	}

	var args []string
	if err := json.Unmarshal([]byte(encoded), &args); err != nil {
		t.Fatal(err)
	}
	os.Args = append([]string{cliName}, args...)
	flag.CommandLine = flag.NewFlagSet(cliName, flag.ExitOnError)
	main()
}
