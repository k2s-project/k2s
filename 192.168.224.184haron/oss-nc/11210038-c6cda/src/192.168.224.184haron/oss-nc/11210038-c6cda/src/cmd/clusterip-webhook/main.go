// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	ve "github.com/k2s-project/k2s/internal/version"
	admissionv1 "k8s.io/api/admission/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	cliName = "clusterip-webhook"

	nodeOSKey = "kubernetes.io/os"

	defaultLinuxSubnet   = "172.21.0.0/24"
	defaultWindowsSubnet = "172.21.1.0/24"
	defaultReservedIPs   = 50 // IPs 0-49 are reserved by K2s

	certFile = "/certs/tls.crt"
	keyFile  = "/certs/tls.key"

	cacheTTL = 30 * time.Second

	// inFlightTTL: hold time between webhook response and API persistence. 10s is conservative; normal < 1s.
	inFlightTTL = 10 * time.Second

	// inFlightCleanupInterval is how often the background cleanup goroutine runs.
	inFlightCleanupInterval = 5 * time.Second
)

var (
	scheme = runtime.NewScheme()
	codecs = serializer.NewCodecFactory(scheme)
)

func main() {
	var addr string
	var linuxSubnet string
	var windowsSubnet string
	var reservedIPs int
	var tlsCert string
	var tlsKey string

	var initCert bool
	var webhookName string
	var serviceName string
	var namespace string

	versionFlag := cli.NewVersionFlag(cliName)
	flag.StringVar(&addr, "addr", ":8443", "address to listen on")
	flag.StringVar(&linuxSubnet, "linux-subnet", defaultLinuxSubnet, "CIDR for Linux service ClusterIPs")
	flag.StringVar(&windowsSubnet, "windows-subnet", defaultWindowsSubnet, "CIDR for Windows service ClusterIPs")
	flag.IntVar(&reservedIPs, "reserved-ips", defaultReservedIPs, "number of IPs reserved at the start of each subnet")
	flag.StringVar(&tlsCert, "tls-cert", certFile, "path to TLS certificate")
	flag.StringVar(&tlsKey, "tls-key", keyFile, "path to TLS private key")
	flag.BoolVar(&initCert, "init-cert", false, "generate TLS certificate and patch webhook config, then exit")
	flag.StringVar(&webhookName, "webhook-name", "k2s-webhook", "name of the MutatingWebhookConfiguration to patch (init-cert mode)")
	flag.StringVar(&serviceName, "service-name", "clusterip-webhook", "service name for TLS certificate SANs (init-cert mode)")
	flag.StringVar(&namespace, "namespace", "k2s-webhook", "namespace of the webhook service (init-cert mode)")
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}

	if initCert {
		slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
		if err := runCertGen(certGenConfig{
			CertPath:    tlsCert,
			KeyPath:     tlsKey,
			ServiceName: serviceName,
			Namespace:   namespace,
			WebhookName: webhookName,
		}); err != nil {
			slog.Error("Certificate generation failed", "error", err)
			os.Exit(1)
		}
		slog.Info("Init-cert completed successfully")
		return
	}

	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
	slog.Info("Starting", "name", cliName, "version", ve.GetVersion().String(), "addr", addr,
		"linuxSubnet", linuxSubnet, "windowsSubnet", windowsSubnet, "reservedIPs", reservedIPs)

	config, err := rest.InClusterConfig()
	if err != nil {
		slog.Error("Failed to create in-cluster config", "error", err)
		os.Exit(1)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		slog.Error("Failed to create Kubernetes clientset", "error", err)
		os.Exit(1)
	}

	allocator, err := NewIPAllocator(linuxSubnet, windowsSubnet, reservedIPs)
	if err != nil {
		slog.Error("Failed to create IP allocator", "error", err)
		os.Exit(1)
	}

	cleanupCtx, cleanupCancel := context.WithCancel(context.Background())
	defer cleanupCancel()
	allocator.StartCleanupLoop(cleanupCtx)

	handler := &WebhookHandler{
		clientset: clientset,
		allocator: allocator,
		cache:     NewOSCache(cacheTTL),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", handler.handleMutate)
	mux.HandleFunc("/mutate-workload", handler.handleMutateWorkload)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	tlsCertPair, err := tls.LoadX509KeyPair(tlsCert, tlsKey)
	if err != nil {
		slog.Error("Failed to load TLS certificate", "error", err, "cert", tlsCert, "key", tlsKey)
		os.Exit(1)
	}

	server := &http.Server{
		Addr:    addr,
		Handler: mux,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{tlsCertPair},
			MinVersion:   tls.VersionTLS12,
		},
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		slog.Info("Listening", "addr", addr)
		if err := server.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
			slog.Error("Server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-stop
	slog.Info("Shutting down")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		slog.Error("Shutdown error", "error", err)
	}
}

// WebhookHandler handles admission review requests for Service resources.
type WebhookHandler struct {
	clientset kubernetes.Interface
	allocator *IPAllocator
	cache     *OSCache
}

func (h *WebhookHandler) handleMutate(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		slog.Error("Failed to read request body", "error", err)
		http.Error(w, "failed to read body", http.StatusBadRequest)
		return
	}

	admissionReview := admissionv1.AdmissionReview{}
	if err := json.Unmarshal(body, &admissionReview); err != nil {
		slog.Error("Failed to unmarshal AdmissionReview", "error", err)
		http.Error(w, "failed to unmarshal", http.StatusBadRequest)
		return
	}

	request := admissionReview.Request
	if request == nil {
		slog.Error("AdmissionReview request is nil")
		http.Error(w, "empty request", http.StatusBadRequest)
		return
	}

	slog.Info("Received admission request",
		"uid", request.UID,
		"kind", request.Kind.Kind,
		"namespace", request.Namespace,
		"name", request.Name,
		"operation", request.Operation)

	response := h.mutateService(request)

	admissionReview.Response = response
	admissionReview.Response.UID = request.UID

	respBytes, err := json.Marshal(admissionReview)
	if err != nil {
		slog.Error("Failed to marshal response", "error", err)
		http.Error(w, "failed to marshal response", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(respBytes)
}

func (h *WebhookHandler) mutateService(request *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
	// Only process Service CREATE requests
	if request.Kind.Kind != "Service" || request.Operation != admissionv1.Create {
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	var service corev1.Service
	if err := json.Unmarshal(request.Object.Raw, &service); err != nil {
		slog.Error("Failed to unmarshal Service", "error", err)
		return &admissionv1.AdmissionResponse{
			Allowed: false,
			Result: &metav1.Status{
				Message: fmt.Sprintf("failed to unmarshal service: %v", err),
			},
		}
	}

	// Skip if clusterIP is already set explicitly
	if service.Spec.ClusterIP != "" && service.Spec.ClusterIP != "None" {
		slog.Info("Service already has clusterIP, skipping",
			"name", service.Name, "namespace", service.Namespace, "clusterIP", service.Spec.ClusterIP)
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	// Skip headless services (check both singular and plural fields)
	if service.Spec.ClusterIP == "None" || containsNone(service.Spec.ClusterIPs) {
		slog.Info("Service is headless, skipping", "name", service.Name, "namespace", service.Namespace)
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	// Skip non-ClusterIP service types (ExternalName has no clusterIP)
	if service.Spec.Type == corev1.ServiceTypeExternalName {
		slog.Info("Service is ExternalName, skipping", "name", service.Name, "namespace", service.Namespace)
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	// Determine target OS by inspecting workloads that match the Service selector
	targetOS := h.detectTargetOS(service.Namespace, service.Spec.Selector)
	slog.Info("Detected target OS", "os", targetOS, "name", service.Name, "namespace", service.Namespace)

	// Serialize with concurrent admissions to prevent duplicate IP allocation.
	h.allocator.mu.Lock()

	usedIPs, err := h.getUsedClusterIPs()
	if err != nil {
		h.allocator.mu.Unlock()
		slog.Error("Failed to list existing services", "error", err)
		return &admissionv1.AdmissionResponse{
			Allowed: false,
			Result: &metav1.Status{
				Message: fmt.Sprintf("failed to list existing services: %v", err),
			},
		}
	}

	// Include IPs allocated by concurrent in-flight admissions not yet persisted.
	h.allocator.cleanupExpiredInFlight()
	for ip := range h.allocator.inFlight {
		usedIPs[ip] = true
	}

	ip, err := h.allocator.AllocateIP(targetOS, usedIPs)
	if err != nil {
		h.allocator.mu.Unlock()
		slog.Error("Failed to allocate IP", "error", err, "os", targetOS,
			"name", service.Name, "namespace", service.Namespace)
		return &admissionv1.AdmissionResponse{
			Allowed: false,
			Result: &metav1.Status{
				Message: fmt.Sprintf("failed to allocate ClusterIP for %s service: %v", targetOS, err),
			},
		}
	}

	h.allocator.markInFlight(ip)
	h.allocator.mu.Unlock()

	slog.Info("Allocating ClusterIP",
		"name", service.Name, "namespace", service.Namespace,
		"os", targetOS, "clusterIP", ip)

	// Create JSON patch to set spec.clusterIP
	patch := fmt.Sprintf(`[{"op": "add", "path": "/spec/clusterIP", "value": "%s"}]`, ip)
	patchType := admissionv1.PatchTypeJSONPatch

	return &admissionv1.AdmissionResponse{
		Allowed:   true,
		PatchType: &patchType,
		Patch:     []byte(patch),
	}
}

func (h *WebhookHandler) getUsedClusterIPs() (map[string]bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	services, err := h.clientset.CoreV1().Services("").List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("listing services: %w", err)
	}

	used := make(map[string]bool, len(services.Items))
	for _, svc := range services.Items {
		if svc.Spec.ClusterIP != "" && svc.Spec.ClusterIP != "None" {
			used[svc.Spec.ClusterIP] = true
		}
	}

	// Also include IPs tracked by the API server's internal allocator.
	// This catches stale bitmap entries and IPs allocated during webhook downtime.
	ipAddresses, err := h.clientset.NetworkingV1().IPAddresses().List(ctx, metav1.ListOptions{})
	if err != nil {
		slog.Warn("Failed to list IPAddress objects, relying on service list only", "error", err)
	} else {
		for _, ipa := range ipAddresses.Items {
			used[ipa.Name] = true
		}
	}

	return used, nil
}

// detectTargetOS discovers the OS for a Service by checking in order:
//  1. In-memory cache (populated by recent workload admissions)
//  2. Existing workloads' nodeSelector (Deployments/StatefulSets/DaemonSets)
//  3. Running Pods → their Node's kubernetes.io/os label
//  4. Defaults to "linux"
func (h *WebhookHandler) detectTargetOS(namespace string, selector map[string]string) string {
	if len(selector) == 0 {
		slog.Info("Service has no selector, defaulting to linux", "namespace", namespace)
		return "linux"
	}

	// Strategy 1: Check in-memory cache from recent workload admissions
	if os := h.cache.Lookup(namespace, selector); os != "" {
		slog.Info("OS found in cache", "os", os, "namespace", namespace)
		return os
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Strategy 2: Check workload nodeSelectors
	if os := h.detectOSFromWorkloads(ctx, namespace, selector); os != "" {
		return os
	}

	// Strategy 3: Check running pods → node labels
	if os := h.detectOSFromPods(ctx, namespace, selector); os != "" {
		return os
	}

	slog.Info("No OS detected from cache, workloads, or pods, defaulting to linux", "namespace", namespace)
	return "linux"
}

// detectOSFromWorkloads checks Deployments, StatefulSets, and DaemonSets in the
// namespace for a pod template whose labels are a superset of the Service selector
// and whose nodeSelector contains kubernetes.io/os.
func (h *WebhookHandler) detectOSFromWorkloads(ctx context.Context, namespace string, selector map[string]string) string {
	selectorSet := labels.Set(selector)

	deployments, err := h.clientset.AppsV1().Deployments(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		slog.Warn("Failed to list Deployments", "error", err, "namespace", namespace)
	} else {
		if os := osFromPodSpecs(deployments.Items, selectorSet); os != "" {
			return os
		}
	}

	statefulSets, err := h.clientset.AppsV1().StatefulSets(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		slog.Warn("Failed to list StatefulSets", "error", err, "namespace", namespace)
	} else {
		if os := osFromPodSpecs(statefulSets.Items, selectorSet); os != "" {
			return os
		}
	}

	daemonSets, err := h.clientset.AppsV1().DaemonSets(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		slog.Warn("Failed to list DaemonSets", "error", err, "namespace", namespace)
	} else {
		if os := osFromPodSpecs(daemonSets.Items, selectorSet); os != "" {
			return os
		}
	}

	return ""
}

// workload is satisfied by Deployment, StatefulSet, and DaemonSet.
type workload interface {
	appsv1.Deployment | appsv1.StatefulSet | appsv1.DaemonSet
}

func osFromPodSpecs[T workload](items []T, selectorSet labels.Set) string {
	for i := range items {
		var podLabels map[string]string
		var nodeSelector map[string]string
		switch w := any(&items[i]).(type) {
		case *appsv1.Deployment:
			podLabels = w.Spec.Template.Labels
			nodeSelector = w.Spec.Template.Spec.NodeSelector
		case *appsv1.StatefulSet:
			podLabels = w.Spec.Template.Labels
			nodeSelector = w.Spec.Template.Spec.NodeSelector
		case *appsv1.DaemonSet:
			podLabels = w.Spec.Template.Labels
			nodeSelector = w.Spec.Template.Spec.NodeSelector
		}
		if !selectorSet.AsSelector().Matches(labels.Set(podLabels)) {
			continue
		}
		if os, ok := nodeSelector[nodeOSKey]; ok {
			return strings.ToLower(os)
		}
	}
	return ""
}

// detectOSFromPods finds pods matching the selector, then checks their node's
// kubernetes.io/os label.
func (h *WebhookHandler) detectOSFromPods(ctx context.Context, namespace string, selector map[string]string) string {
	labelParts := make([]string, 0, len(selector))
	for k, v := range selector {
		labelParts = append(labelParts, k+"="+v)
	}
	labelSelector := strings.Join(labelParts, ",")

	pods, err := h.clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{LabelSelector: labelSelector})
	if err != nil {
		slog.Warn("Failed to list Pods", "error", err, "namespace", namespace)
		return ""
	}

	for _, pod := range pods.Items {
		if pod.Spec.NodeName == "" {
			continue
		}
		node, err := h.clientset.CoreV1().Nodes().Get(ctx, pod.Spec.NodeName, metav1.GetOptions{})
		if err != nil {
			slog.Warn("Failed to get Node", "error", err, "node", pod.Spec.NodeName)
			continue
		}
		if os, ok := node.Labels[nodeOSKey]; ok {
			return strings.ToLower(os)
		}
	}

	return ""
}

// handleMutateWorkload intercepts Deployment/StatefulSet/DaemonSet CREATE requests.
// It caches the OS from the workload's nodeSelector and, if the workload targets
// Windows, reconciles any matching Services that may have been assigned a Linux ClusterIP.
func (h *WebhookHandler) handleMutateWorkload(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		slog.Error("Failed to read request body", "error", err)
		http.Error(w, "failed to read body", http.StatusBadRequest)
		return
	}

	admissionReview := admissionv1.AdmissionReview{}
	if err := json.Unmarshal(body, &admissionReview); err != nil {
		slog.Error("Failed to unmarshal AdmissionReview", "error", err)
		http.Error(w, "failed to unmarshal", http.StatusBadRequest)
		return
	}

	request := admissionReview.Request
	if request == nil {
		slog.Error("AdmissionReview request is nil")
		http.Error(w, "empty request", http.StatusBadRequest)
		return
	}

	slog.Info("Received workload admission request",
		"uid", request.UID,
		"kind", request.Kind.Kind,
		"namespace", request.Namespace,
		"name", request.Name,
		"operation", request.Operation)

	response := h.processWorkload(request)

	admissionReview.Response = response
	admissionReview.Response.UID = request.UID

	respBytes, err := json.Marshal(admissionReview)
	if err != nil {
		slog.Error("Failed to marshal response", "error", err)
		http.Error(w, "failed to marshal response", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(respBytes)
}

// processWorkload extracts the nodeSelector and pod template labels from a workload,
// caches the OS, and reconciles mismatched Services if the workload targets Windows.
func (h *WebhookHandler) processWorkload(request *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
	if request.Operation != admissionv1.Create {
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	podLabels, nodeSelector, err := extractWorkloadInfo(request)
	if err != nil {
		slog.Warn("Failed to extract workload info", "error", err,
			"kind", request.Kind.Kind, "name", request.Name)
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	os, hasOS := nodeSelector[nodeOSKey]
	if !hasOS {
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	os = strings.ToLower(os)
	h.cache.Store(request.Namespace, podLabels, os)
	slog.Info("Cached OS from workload",
		"os", os, "kind", request.Kind.Kind, "name", request.Name, "namespace", request.Namespace)

	// Only reconcile for Windows workloads — Linux is the default, so Services
	// already got the correct IP. Skip reconciliation on dry-run requests.
	if os == "windows" && (request.DryRun == nil || !*request.DryRun) {
		h.reconcileMismatchedServices(request.Namespace, podLabels)
	}

	return &admissionv1.AdmissionResponse{Allowed: true}
}

// extractWorkloadInfo returns the pod template labels and nodeSelector from a
// Deployment, StatefulSet, or DaemonSet admission request.
func extractWorkloadInfo(request *admissionv1.AdmissionRequest) (podLabels, nodeSelector map[string]string, err error) {
	switch request.Kind.Kind {
	case "Deployment":
		var d appsv1.Deployment
		if err := json.Unmarshal(request.Object.Raw, &d); err != nil {
			return nil, nil, fmt.Errorf("unmarshal Deployment: %w", err)
		}
		return d.Spec.Template.Labels, d.Spec.Template.Spec.NodeSelector, nil
	case "StatefulSet":
		var s appsv1.StatefulSet
		if err := json.Unmarshal(request.Object.Raw, &s); err != nil {
			return nil, nil, fmt.Errorf("unmarshal StatefulSet: %w", err)
		}
		return s.Spec.Template.Labels, s.Spec.Template.Spec.NodeSelector, nil
	case "DaemonSet":
		var d appsv1.DaemonSet
		if err := json.Unmarshal(request.Object.Raw, &d); err != nil {
			return nil, nil, fmt.Errorf("unmarshal DaemonSet: %w", err)
		}
		return d.Spec.Template.Labels, d.Spec.Template.Spec.NodeSelector, nil
	default:
		return nil, nil, fmt.Errorf("unsupported kind: %s", request.Kind.Kind)
	}
}

// reconcileMismatchedServices finds Services in the namespace whose selector
// matches the workload's pod labels and whose ClusterIP is in the Linux subnet
// (assigned by default before the Windows workload existed). It deletes each
// such Service and recreates it without a ClusterIP so the webhook can reassign
// the correct Windows IP on the new CREATE admission.
func (h *WebhookHandler) reconcileMismatchedServices(namespace string, podLabels map[string]string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	services, err := h.clientset.CoreV1().Services(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		slog.Error("Failed to list services for reconciliation", "error", err, "namespace", namespace)
		return
	}

	podLabelSet := labels.Set(podLabels)

	for _, svc := range services.Items {
		if svc.Spec.ClusterIP == "" || svc.Spec.ClusterIP == "None" {
			continue
		}
		if svc.Spec.Type == corev1.ServiceTypeExternalName {
			continue
		}

		// Check if the service selector matches the workload's pod labels
		svcSelector := labels.Set(svc.Spec.Selector)
		if len(svcSelector) == 0 || !svcSelector.AsSelector().Matches(podLabelSet) {
			continue
		}

		// Check if the ClusterIP is in the Linux subnet (wrong for a Windows workload)
		if !h.allocator.IsInLinuxSubnet(svc.Spec.ClusterIP) {
			continue
		}

		slog.Info("Reconciling mismatched Service",
			"service", svc.Name, "namespace", namespace,
			"currentIP", svc.Spec.ClusterIP, "reason", "workload targets windows")

		if err := h.deleteAndRecreateService(ctx, &svc); err != nil {
			slog.Error("Failed to reconcile Service",
				"error", err, "service", svc.Name, "namespace", namespace)
		}
	}
}

// deleteAndRecreateService deletes a Service and recreates it without a ClusterIP,
// allowing the webhook to assign the correct IP on the new CREATE.
func (h *WebhookHandler) deleteAndRecreateService(ctx context.Context, svc *corev1.Service) error {
	namespace := svc.Namespace
	name := svc.Name

	if err := h.clientset.CoreV1().Services(namespace).Delete(ctx, name, metav1.DeleteOptions{}); err != nil {
		return fmt.Errorf("delete service %s/%s: %w", namespace, name, err)
	}

	newSvc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:        name,
			Namespace:   namespace,
			Labels:      svc.Labels,
			Annotations: svc.Annotations,
		},
		Spec: corev1.ServiceSpec{
			Selector: svc.Spec.Selector,
			Ports:    svc.Spec.Ports,
			Type:     svc.Spec.Type,
		},
	}

	if _, err := h.clientset.CoreV1().Services(namespace).Create(ctx, newSvc, metav1.CreateOptions{}); err != nil {
		return fmt.Errorf("recreate service %s/%s: %w", namespace, name, err)
	}

	slog.Info("Service recreated for correct ClusterIP assignment",
		"service", name, "namespace", namespace)
	return nil
}

// OSCache is a thread-safe, TTL-based cache mapping workload pod labels to
// their target OS. It bridges the timing gap when Services and workloads are
// applied simultaneously — the workload admission populates the cache, and
// the recreated Service admission reads it.
type OSCache struct {
	mu      sync.RWMutex
	entries map[string]osCacheEntry
	ttl     time.Duration
}

type osCacheEntry struct {
	os        string
	expiresAt time.Time
}

func NewOSCache(ttl time.Duration) *OSCache {
	return &OSCache{
		entries: make(map[string]osCacheEntry),
		ttl:     ttl,
	}
}

// Store caches the OS for a given namespace + pod label combination.
func (c *OSCache) Store(namespace string, podLabels map[string]string, os string) {
	key := cacheKey(namespace, podLabels)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[key] = osCacheEntry{os: os, expiresAt: time.Now().Add(c.ttl)}
}

// Lookup returns the cached OS for the given namespace + service selector.
// Returns "" if no matching entry exists or the entry has expired.
func (c *OSCache) Lookup(namespace string, selector map[string]string) string {
	key := cacheKey(namespace, selector)
	c.mu.RLock()
	defer c.mu.RUnlock()
	entry, ok := c.entries[key]
	if !ok || time.Now().After(entry.expiresAt) {
		return ""
	}
	return entry.os
}

// cacheKey produces a deterministic key from namespace and labels.
func cacheKey(namespace string, lbls map[string]string) string {
	keys := make([]string, 0, len(lbls))
	for k := range lbls {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(namespace)
	for _, k := range keys {
		b.WriteByte('/')
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(lbls[k])
	}
	return b.String()
}

// IsInLinuxSubnet checks whether the given IP falls within the Linux ClusterIP range.
func (a *IPAllocator) IsInLinuxSubnet(ip string) bool {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false
	}
	parsed = parsed.To4()
	if parsed == nil {
		return false
	}
	return !bytesGreater(dupIP(a.linuxStart), parsed) && !bytesGreater(parsed, dupIP(a.linuxEnd))
}

// IPAllocator manages IP allocation from Linux and Windows subnets.
//
// Thread safety: mu serializes all allocation; inFlight bridges the gap between webhook response and API persistence, expiring after inFlightTTL.
//
// Single-replica only -- inFlight is in-process; scale to >1 requires a shared store (e.g. IPPool CRD).
type IPAllocator struct {
	mu           sync.Mutex
	inFlight     map[string]time.Time
	linuxStart   net.IP
	linuxEnd     net.IP
	windowsStart net.IP
	windowsEnd   net.IP
}

// NewIPAllocator creates an allocator for the given CIDR ranges,
// skipping the first reservedIPs addresses in each subnet.
func NewIPAllocator(linuxCIDR, windowsCIDR string, reservedIPs int) (*IPAllocator, error) {
	linuxStart, linuxEnd, err := subnetRange(linuxCIDR, reservedIPs)
	if err != nil {
		return nil, fmt.Errorf("invalid linux CIDR %q: %w", linuxCIDR, err)
	}

	windowsStart, windowsEnd, err := subnetRange(windowsCIDR, reservedIPs)
	if err != nil {
		return nil, fmt.Errorf("invalid windows CIDR %q: %w", windowsCIDR, err)
	}

	return &IPAllocator{
		inFlight:     make(map[string]time.Time),
		linuxStart:   linuxStart,
		linuxEnd:     linuxEnd,
		windowsStart: windowsStart,
		windowsEnd:   windowsEnd,
	}, nil
}

// AllocateIP returns the next available IP in the appropriate subnet.
// The caller is responsible for marking the returned IP as in-flight before releasing the mutex.
func (a *IPAllocator) AllocateIP(osType string, usedIPs map[string]bool) (string, error) {
	var start, end net.IP
	if osType == "windows" {
		start = a.windowsStart
		end = a.windowsEnd
	} else {
		start = a.linuxStart
		end = a.linuxEnd
	}

	for ip := dupIP(start); ; incIP(ip) {
		candidate := ip.String()
		if !usedIPs[candidate] {
			return candidate, nil
		}
		if ip.Equal(end) {
			break
		}
	}

	return "", fmt.Errorf("no free IPs in %s subnet (range %s - %s)", osType, start, end)
}

// markInFlight records ip as in-flight. Must be called with mu held.
func (a *IPAllocator) markInFlight(ip string) {
	a.inFlight[ip] = time.Now().Add(inFlightTTL)
}

// cleanupExpiredInFlight evicts in-flight entries whose TTL has elapsed.
// Must be called with mu held.
func (a *IPAllocator) cleanupExpiredInFlight() {
	now := time.Now()
	for ip, expiry := range a.inFlight {
		if now.After(expiry) {
			slog.Info("Evicted stale in-flight IP", "ip", ip)
			delete(a.inFlight, ip)
		}
	}
}

// StartCleanupLoop runs a background goroutine that periodically evicts expired
// in-flight entries. It exits when ctx is cancelled (e.g. on webhook shutdown).
func (a *IPAllocator) StartCleanupLoop(ctx context.Context) {
	go func() {
		ticker := time.NewTicker(inFlightCleanupInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				a.mu.Lock()
				a.cleanupExpiredInFlight()
				a.mu.Unlock()
			case <-ctx.Done():
				return
			}
		}
	}()
}

// subnetRange returns the allocatable IP range [start, end] for a CIDR,
// skipping the network address and the first reservedIPs host addresses,
// and excluding the broadcast address.
func subnetRange(cidr string, reservedIPs int) (net.IP, net.IP, error) {
	_, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, nil, err
	}

	// Start = network + reservedIPs (skip .0 through .reservedIPs-1)
	start := dupIP(ipNet.IP)
	for i := 0; i < reservedIPs; i++ {
		incIP(start)
	}

	// End = broadcast - 1
	end := broadcastAddr(ipNet)
	decIP(end)

	if start.Equal(end) || bytesGreater(start, end) {
		return nil, nil, fmt.Errorf("subnet %s too small for %d reserved IPs", cidr, reservedIPs)
	}

	return start, end, nil
}

func broadcastAddr(n *net.IPNet) net.IP {
	ip := dupIP(n.IP)
	for i := range ip {
		ip[i] |= ^n.Mask[i]
	}
	return ip
}

func dupIP(ip net.IP) net.IP {
	dup := make(net.IP, len(ip))
	copy(dup, ip)
	return dup
}

func incIP(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++
		if ip[j] > 0 {
			break
		}
	}
}

func decIP(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]--
		if ip[j] < 255 {
			break
		}
	}
}

func bytesGreater(a, b net.IP) bool {
	for i := range a {
		if a[i] > b[i] {
			return true
		}
		if a[i] < b[i] {
			return false
		}
	}
	return false
}

func containsNone(clusterIPs []string) bool {
	for _, ip := range clusterIPs {
		if ip == "None" {
			return true
		}
	}
	return false
}
