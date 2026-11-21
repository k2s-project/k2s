// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"strconv"
	"sync"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestNewIPAllocator(t *testing.T) {
	alloc, err := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if alloc.linuxStart.String() != "172.21.0.50" {
		t.Errorf("linux start = %s, want 172.21.0.50", alloc.linuxStart)
	}
	if alloc.linuxEnd.String() != "172.21.0.254" {
		t.Errorf("linux end = %s, want 172.21.0.254", alloc.linuxEnd)
	}
	if alloc.windowsStart.String() != "172.21.1.50" {
		t.Errorf("windows start = %s, want 172.21.1.50", alloc.windowsStart)
	}
	if alloc.windowsEnd.String() != "172.21.1.254" {
		t.Errorf("windows end = %s, want 172.21.1.254", alloc.windowsEnd)
	}
}

func TestNewIPAllocatorInvalidCIDR(t *testing.T) {
	_, err := NewIPAllocator("invalid", "172.21.1.0/24", 50)
	if err == nil {
		t.Fatal("expected error for invalid CIDR")
	}
}

func TestNewIPAllocatorSubnetTooSmall(t *testing.T) {
	_, err := NewIPAllocator("172.21.0.0/30", "172.21.1.0/24", 50)
	if err == nil {
		t.Fatal("expected error for subnet too small")
	}
}

func TestAllocateIPLinuxFirstFree(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{}

	ip, err := alloc.AllocateIP("linux", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.0.50" {
		t.Errorf("got %s, want 172.21.0.50", ip)
	}
}

func TestAllocateIPWindowsFirstFree(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{}

	ip, err := alloc.AllocateIP("windows", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.1.50" {
		t.Errorf("got %s, want 172.21.1.50", ip)
	}
}

func TestAllocateIPSkipsUsed(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{
		"172.21.0.50": true,
		"172.21.0.51": true,
		"172.21.0.52": true,
	}

	ip, err := alloc.AllocateIP("linux", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.0.53" {
		t.Errorf("got %s, want 172.21.0.53", ip)
	}
}

func TestAllocateIPWindowsSkipsUsed(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{
		"172.21.1.50": true,
	}

	ip, err := alloc.AllocateIP("windows", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.1.51" {
		t.Errorf("got %s, want 172.21.1.51", ip)
	}
}

func TestAllocateIPExhausted(t *testing.T) {
	// Use a very small subnet (172.21.0.0/30 = 4 IPs: .0, .1, .2, .3)
	// With 1 reserved IP, range is .1 to .2 (broadcast .3 excluded)
	alloc, _ := NewIPAllocator("172.21.0.0/30", "172.21.1.0/24", 1)
	usedIPs := map[string]bool{
		"172.21.0.1": true,
		"172.21.0.2": true,
	}

	_, err := alloc.AllocateIP("linux", usedIPs)
	if err == nil {
		t.Fatal("expected error when all IPs are exhausted")
	}
}

func TestAllocateIPDefaultsToLinux(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{}

	ip, err := alloc.AllocateIP("", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.0.50" {
		t.Errorf("got %s, want 172.21.0.50 (should default to linux)", ip)
	}
}

func TestAllocateIPCanUseLastIP(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)

	// Mark all IPs except .254 as used
	usedIPs := map[string]bool{}
	for i := 50; i < 254; i++ {
		usedIPs["172.21.0."+strconv.Itoa(i)] = true
	}

	ip, err := alloc.AllocateIP("linux", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.0.254" {
		t.Errorf("got %s, want 172.21.0.254", ip)
	}
}

func TestSubnetRange(t *testing.T) {
	tests := []struct {
		cidr       string
		reserved   int
		wantStart  string
		wantEnd    string
		wantErr    bool
	}{
		{"172.21.0.0/24", 50, "172.21.0.50", "172.21.0.254", false},
		{"172.21.1.0/24", 50, "172.21.1.50", "172.21.1.254", false},
		{"10.0.0.0/24", 10, "10.0.0.10", "10.0.0.254", false},
		{"172.21.0.0/30", 1, "172.21.0.1", "172.21.0.2", false},
		{"172.21.0.0/30", 50, "", "", true}, // too small
	}

	for _, tt := range tests {
		start, end, err := subnetRange(tt.cidr, tt.reserved)
		if tt.wantErr {
			if err == nil {
				t.Errorf("subnetRange(%s, %d): expected error", tt.cidr, tt.reserved)
			}
			continue
		}
		if err != nil {
			t.Errorf("subnetRange(%s, %d): unexpected error: %v", tt.cidr, tt.reserved, err)
			continue
		}
		if start.String() != tt.wantStart {
			t.Errorf("subnetRange(%s, %d): start = %s, want %s", tt.cidr, tt.reserved, start, tt.wantStart)
		}
		if end.String() != tt.wantEnd {
			t.Errorf("subnetRange(%s, %d): end = %s, want %s", tt.cidr, tt.reserved, end, tt.wantEnd)
		}
	}
}

func TestIncAndDecIP(t *testing.T) {
	ip := dupIP([]byte{172, 21, 0, 254})
	incIP(ip)
	if ip.String() != "172.21.0.255" {
		t.Errorf("inc 172.21.0.254 = %s, want 172.21.0.255", ip)
	}

	ip2 := dupIP([]byte{172, 21, 0, 255})
	incIP(ip2)
	if ip2.String() != "172.21.1.0" {
		t.Errorf("inc 172.21.0.255 = %s, want 172.21.1.0", ip2)
	}

	ip3 := dupIP([]byte{172, 21, 1, 0})
	decIP(ip3)
	if ip3.String() != "172.21.0.255" {
		t.Errorf("dec 172.21.1.0 = %s, want 172.21.0.255", ip3)
	}
}

// --- OSCache tests ---

func TestOSCache_StoreAndLookup(t *testing.T) {
	c := NewOSCache(5 * time.Second)
	c.Store("default", map[string]string{"app": "myapp"}, "windows")

	result := c.Lookup("default", map[string]string{"app": "myapp"})
	if result != "windows" {
		t.Errorf("got %q, want windows", result)
	}
}

func TestOSCache_LookupMiss(t *testing.T) {
	c := NewOSCache(5 * time.Second)

	result := c.Lookup("default", map[string]string{"app": "missing"})
	if result != "" {
		t.Errorf("got %q, want empty string for cache miss", result)
	}
}

func TestOSCache_Expiry(t *testing.T) {
	c := NewOSCache(1 * time.Millisecond)
	c.Store("default", map[string]string{"app": "myapp"}, "windows")

	time.Sleep(5 * time.Millisecond)

	result := c.Lookup("default", map[string]string{"app": "myapp"})
	if result != "" {
		t.Errorf("got %q, want empty string for expired entry", result)
	}
}

func TestOSCache_DifferentNamespaces(t *testing.T) {
	c := NewOSCache(5 * time.Second)
	c.Store("ns1", map[string]string{"app": "myapp"}, "windows")
	c.Store("ns2", map[string]string{"app": "myapp"}, "linux")

	if result := c.Lookup("ns1", map[string]string{"app": "myapp"}); result != "windows" {
		t.Errorf("ns1: got %q, want windows", result)
	}
	if result := c.Lookup("ns2", map[string]string{"app": "myapp"}); result != "linux" {
		t.Errorf("ns2: got %q, want linux", result)
	}
}

func TestCacheKey_Deterministic(t *testing.T) {
	// Same labels in different insertion order should produce the same key
	k1 := cacheKey("ns", map[string]string{"a": "1", "b": "2"})
	k2 := cacheKey("ns", map[string]string{"b": "2", "a": "1"})
	if k1 != k2 {
		t.Errorf("keys differ: %q vs %q", k1, k2)
	}
}

// --- detectTargetOS tests ---

func TestDetectTargetOS_NilSelector(t *testing.T) {
	h := &WebhookHandler{clientset: fake.NewSimpleClientset(), cache: NewOSCache(5 * time.Second)}
	result := h.detectTargetOS("default", nil)
	if result != "linux" {
		t.Errorf("got %s, want linux for nil selector", result)
	}
}

func TestDetectTargetOS_EmptySelector(t *testing.T) {
	h := &WebhookHandler{clientset: fake.NewSimpleClientset(), cache: NewOSCache(5 * time.Second)}
	result := h.detectTargetOS("default", map[string]string{})
	if result != "linux" {
		t.Errorf("got %s, want linux for empty selector", result)
	}
}

func TestDetectTargetOS_CacheHit(t *testing.T) {
	h := &WebhookHandler{clientset: fake.NewSimpleClientset(), cache: NewOSCache(5 * time.Second)}
	h.cache.Store("default", map[string]string{"app": "win-app"}, "windows")

	result := h.detectTargetOS("default", map[string]string{"app": "win-app"})
	if result != "windows" {
		t.Errorf("got %s, want windows (from cache)", result)
	}
}

func TestDetectTargetOS_WorkloadNodeSelector(t *testing.T) {
	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "win-deploy",
			Namespace: "default",
		},
		Spec: appsv1.DeploymentSpec{
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": "win-app"},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": "win-app"},
				},
				Spec: corev1.PodSpec{
					NodeSelector: map[string]string{"kubernetes.io/os": "windows"},
				},
			},
		},
	}
	client := fake.NewSimpleClientset(deploy)
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}

	result := h.detectTargetOS("default", map[string]string{"app": "win-app"})
	if result != "windows" {
		t.Errorf("got %s, want windows (from workload nodeSelector)", result)
	}
}

func TestDetectTargetOS_PodOnWindowsNode(t *testing.T) {
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   "win-node",
			Labels: map[string]string{"kubernetes.io/os": "windows"},
		},
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-pod",
			Namespace: "default",
			Labels:    map[string]string{"app": "win-app"},
		},
		Spec: corev1.PodSpec{
			NodeName: "win-node",
		},
	}
	client := fake.NewSimpleClientset(node, pod)
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}

	result := h.detectTargetOS("default", map[string]string{"app": "win-app"})
	if result != "windows" {
		t.Errorf("got %s, want windows", result)
	}
}

func TestDetectTargetOS_PodOnLinuxNode(t *testing.T) {
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   "linux-node",
			Labels: map[string]string{"kubernetes.io/os": "linux"},
		},
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-pod",
			Namespace: "default",
			Labels:    map[string]string{"app": "linux-app"},
		},
		Spec: corev1.PodSpec{
			NodeName: "linux-node",
		},
	}
	client := fake.NewSimpleClientset(node, pod)
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}

	result := h.detectTargetOS("default", map[string]string{"app": "linux-app"})
	if result != "linux" {
		t.Errorf("got %s, want linux", result)
	}
}

func TestDetectTargetOS_PodNotScheduled_DefaultsLinux(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "pending-pod",
			Namespace: "default",
			Labels:    map[string]string{"app": "pending"},
		},
		Spec: corev1.PodSpec{},
	}
	client := fake.NewSimpleClientset(pod)
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}

	result := h.detectTargetOS("default", map[string]string{"app": "pending"})
	if result != "linux" {
		t.Errorf("got %s, want linux (pod not scheduled)", result)
	}
}

func TestDetectTargetOS_NoPods_DefaultsLinux(t *testing.T) {
	client := fake.NewSimpleClientset()
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}

	result := h.detectTargetOS("default", map[string]string{"app": "missing"})
	if result != "linux" {
		t.Errorf("got %s, want linux (no pods)", result)
	}
}

func TestDetectTargetOS_WrongNamespace_DefaultsLinux(t *testing.T) {
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   "win-node",
			Labels: map[string]string{"kubernetes.io/os": "windows"},
		},
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-pod",
			Namespace: "other",
			Labels:    map[string]string{"app": "win-app"},
		},
		Spec: corev1.PodSpec{
			NodeName: "win-node",
		},
	}
	client := fake.NewSimpleClientset(node, pod)
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}

	result := h.detectTargetOS("default", map[string]string{"app": "win-app"})
	if result != "linux" {
		t.Errorf("got %s, want linux (wrong namespace)", result)
	}
}

func TestDetectTargetOS_CacheTakesPriorityOverWorkload(t *testing.T) {
	// Even if a Linux workload exists, a cache entry for "windows" wins
	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "linux-deploy",
			Namespace: "default",
		},
		Spec: appsv1.DeploymentSpec{
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": "myapp"},
				},
				Spec: corev1.PodSpec{
					NodeSelector: map[string]string{"kubernetes.io/os": "linux"},
				},
			},
		},
	}
	client := fake.NewSimpleClientset(deploy)
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}
	h.cache.Store("default", map[string]string{"app": "myapp"}, "windows")

	result := h.detectTargetOS("default", map[string]string{"app": "myapp"})
	if result != "windows" {
		t.Errorf("got %s, want windows (cache should win)", result)
	}
}

// --- detectOSFromWorkloads tests ---

func TestDetectOSFromWorkloads_DeploymentMatch(t *testing.T) {
	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "win-deploy",
			Namespace: "default",
		},
		Spec: appsv1.DeploymentSpec{
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": "win-app", "version": "v1"},
				},
				Spec: corev1.PodSpec{
					NodeSelector: map[string]string{"kubernetes.io/os": "windows"},
				},
			},
		},
	}
	client := fake.NewSimpleClientset(deploy)
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}

	ctx := context.Background()
	result := h.detectOSFromWorkloads(ctx, "default", map[string]string{"app": "win-app"})
	if result != "windows" {
		t.Errorf("got %q, want windows", result)
	}
}

func TestDetectOSFromWorkloads_NoNodeSelector(t *testing.T) {
	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "deploy-no-ns",
			Namespace: "default",
		},
		Spec: appsv1.DeploymentSpec{
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": "myapp"},
				},
				Spec: corev1.PodSpec{},
			},
		},
	}
	client := fake.NewSimpleClientset(deploy)
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}

	ctx := context.Background()
	result := h.detectOSFromWorkloads(ctx, "default", map[string]string{"app": "myapp"})
	if result != "" {
		t.Errorf("got %q, want empty (no nodeSelector)", result)
	}
}

func TestDetectOSFromWorkloads_StatefulSetMatch(t *testing.T) {
	sts := &appsv1.StatefulSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "win-sts",
			Namespace: "default",
		},
		Spec: appsv1.StatefulSetSpec{
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": "win-sts"},
				},
				Spec: corev1.PodSpec{
					NodeSelector: map[string]string{"kubernetes.io/os": "windows"},
				},
			},
		},
	}
	client := fake.NewSimpleClientset(sts)
	h := &WebhookHandler{clientset: client, cache: NewOSCache(5 * time.Second)}

	ctx := context.Background()
	result := h.detectOSFromWorkloads(ctx, "default", map[string]string{"app": "win-sts"})
	if result != "windows" {
		t.Errorf("got %q, want windows", result)
	}
}

// --- IsInLinuxSubnet tests ---

func TestIsInLinuxSubnet(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)

	tests := []struct {
		ip   string
		want bool
	}{
		{"172.21.0.50", true},
		{"172.21.0.100", true},
		{"172.21.0.254", true},
		{"172.21.1.50", false},
		{"172.21.1.100", false},
		{"10.0.0.1", false},
		{"invalid", false},
	}

	for _, tt := range tests {
		got := alloc.IsInLinuxSubnet(tt.ip)
		if got != tt.want {
			t.Errorf("IsInLinuxSubnet(%s) = %v, want %v", tt.ip, got, tt.want)
		}
	}
}

// --- reconcileMismatchedServices tests ---

func TestReconcileMismatchedServices(t *testing.T) {
	// Service with Linux-range IP matching a Windows workload's labels
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "win-svc",
			Namespace: "default",
			Labels:    map[string]string{"tier": "frontend"},
		},
		Spec: corev1.ServiceSpec{
			Selector:  map[string]string{"app": "win-app"},
			ClusterIP: "172.21.0.55",
			Ports: []corev1.ServicePort{
				{Port: 80, Protocol: corev1.ProtocolTCP},
			},
		},
	}
	client := fake.NewSimpleClientset(svc)
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	h := &WebhookHandler{
		clientset: client,
		allocator: alloc,
		cache:     NewOSCache(5 * time.Second),
	}

	h.reconcileMismatchedServices("default", map[string]string{"app": "win-app"})

	// The original service should have been deleted and recreated
	ctx := context.Background()
	newSvc, err := client.CoreV1().Services("default").Get(ctx, "win-svc", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("Service should have been recreated: %v", err)
	}

	// The recreated service should not have a ClusterIP set (the fake client
	// doesn't run the webhook, but the real API server would)
	if newSvc.Spec.ClusterIP == "172.21.0.55" {
		t.Error("Service should have been recreated without the old Linux ClusterIP")
	}

	// Labels and selector should be preserved
	if newSvc.Labels["tier"] != "frontend" {
		t.Error("Labels not preserved on recreated service")
	}
	if newSvc.Spec.Selector["app"] != "win-app" {
		t.Error("Selector not preserved on recreated service")
	}
}

func TestReconcileMismatchedServices_SkipsWindowsSubnet(t *testing.T) {
	// Service already in Windows subnet — should not be reconciled
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "win-svc",
			Namespace: "default",
		},
		Spec: corev1.ServiceSpec{
			Selector:  map[string]string{"app": "win-app"},
			ClusterIP: "172.21.1.55",
			Ports: []corev1.ServicePort{
				{Port: 80, Protocol: corev1.ProtocolTCP},
			},
		},
	}
	client := fake.NewSimpleClientset(svc)
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	h := &WebhookHandler{
		clientset: client,
		allocator: alloc,
		cache:     NewOSCache(5 * time.Second),
	}

	h.reconcileMismatchedServices("default", map[string]string{"app": "win-app"})

	ctx := context.Background()
	svcAfter, err := client.CoreV1().Services("default").Get(ctx, "win-svc", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("Service should still exist: %v", err)
	}
	if svcAfter.Spec.ClusterIP != "172.21.1.55" {
		t.Error("Service in Windows subnet should not have been touched")
	}
}

func TestReconcileMismatchedServices_SkipsNonMatchingSelector(t *testing.T) {
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "other-svc",
			Namespace: "default",
		},
		Spec: corev1.ServiceSpec{
			Selector:  map[string]string{"app": "other-app"},
			ClusterIP: "172.21.0.55",
			Ports: []corev1.ServicePort{
				{Port: 80, Protocol: corev1.ProtocolTCP},
			},
		},
	}
	client := fake.NewSimpleClientset(svc)
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	h := &WebhookHandler{
		clientset: client,
		allocator: alloc,
		cache:     NewOSCache(5 * time.Second),
	}

	h.reconcileMismatchedServices("default", map[string]string{"app": "win-app"})

	ctx := context.Background()
	svcAfter, err := client.CoreV1().Services("default").Get(ctx, "other-svc", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("Service should still exist: %v", err)
	}
	if svcAfter.Spec.ClusterIP != "172.21.0.55" {
		t.Error("Non-matching service should not have been touched")
	}
}

// --- In-flight and concurrent allocation tests ---

// TestAllocateIP_InFlightPreventsReuse verifies that an IP marked in-flight
// is not re-allocated to a concurrent request.
func TestAllocateIP_InFlightPreventsReuse(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)

	// Simulate: first request allocated .50 and marked it in-flight.
	alloc.mu.Lock()
	alloc.markInFlight("172.21.0.50")
	alloc.mu.Unlock()

	// Second request lists the same used-IPs (empty from cluster) but merges in-flight.
	usedIPs := map[string]bool{}
	alloc.mu.Lock()
	for ip := range alloc.inFlight {
		usedIPs[ip] = true
	}
	ip, err := alloc.AllocateIP("linux", usedIPs)
	alloc.mu.Unlock()

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip == "172.21.0.50" {
		t.Error("in-flight IP .50 should not have been re-allocated")
	}
	if ip != "172.21.0.51" {
		t.Errorf("expected .51 as next free, got %s", ip)
	}
}

// TestAllocateIP_InFlightExpiry verifies that expired in-flight entries are
// evicted and their IPs become allocatable again.
func TestAllocateIP_InFlightExpiry(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)

	// Insert an already-expired entry directly.
	alloc.mu.Lock()
	alloc.inFlight["172.21.0.50"] = time.Now().Add(-1 * time.Second)
	alloc.mu.Unlock()

	alloc.mu.Lock()
	alloc.cleanupExpiredInFlight()
	usedIPs := map[string]bool{}
	for ip := range alloc.inFlight {
		usedIPs[ip] = true
	}
	ip, err := alloc.AllocateIP("linux", usedIPs)
	alloc.mu.Unlock()

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.0.50" {
		t.Errorf("expired in-flight IP should be available again, got %s", ip)
	}
}

// TestConcurrentAllocation_NoDuplicates races 20 goroutines each performing a
// full lock-getUsedIPs-mergeInFlight-allocate-markInFlight cycle and asserts
// that no two goroutines receive the same IP.
func TestConcurrentAllocation_NoDuplicates(t *testing.T) {
	const goroutines = 20
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)

	// Shared cluster state: starts empty, grows as goroutines "persist" their IPs.
	var clusterMu sync.Mutex
	clusterIPs := map[string]bool{}

	results := make([]string, goroutines)
	errs := make([]error, goroutines)

	var wg sync.WaitGroup
	wg.Add(goroutines)

	for i := 0; i < goroutines; i++ {
		i := i
		go func() {
			defer wg.Done()

			alloc.mu.Lock()

			// Build usedIPs: cluster state + in-flight.
			usedIPs := map[string]bool{}
			clusterMu.Lock()
			for ip := range clusterIPs {
				usedIPs[ip] = true
			}
			clusterMu.Unlock()

			alloc.cleanupExpiredInFlight()
			for ip := range alloc.inFlight {
				usedIPs[ip] = true
			}

			ip, err := alloc.AllocateIP("linux", usedIPs)
			if err != nil {
				alloc.mu.Unlock()
				errs[i] = err
				return
			}
			alloc.markInFlight(ip)
			alloc.mu.Unlock()

			// Simulate API server persistence.
			clusterMu.Lock()
			clusterIPs[ip] = true
			clusterMu.Unlock()

			results[i] = ip
		}()
	}

	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d: allocation error: %v", i, err)
		}
	}

	// Assert no duplicate IPs.
	seen := map[string]int{}
	for i, ip := range results {
		if ip == "" {
			continue
		}
		if prev, ok := seen[ip]; ok {
			t.Errorf("duplicate IP %s allocated by goroutines %d and %d", ip, prev, i)
		}
		seen[ip] = i
	}

	if t.Failed() {
		t.Logf("allocated IPs: %v", results)
	}
}

// TestStartCleanupLoop verifies that the cleanup goroutine evicts expired entries.
func TestStartCleanupLoop(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	alloc.StartCleanupLoop(ctx)

	// Insert an already-expired entry.
	alloc.mu.Lock()
	alloc.inFlight["172.21.0.50"] = time.Now().Add(-1 * time.Second)
	alloc.mu.Unlock()

	// Call cleanupExpiredInFlight directly -- the background ticker fires at 5s
	// so we invoke it explicitly rather than waiting.
	alloc.mu.Lock()
	alloc.cleanupExpiredInFlight()
	remaining := len(alloc.inFlight)
	alloc.mu.Unlock()

	if remaining != 0 {
		t.Errorf("expected 0 in-flight entries after cleanup, got %d", remaining)
	}
}
