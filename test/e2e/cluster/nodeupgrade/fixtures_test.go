// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package nodeupgrade

import (
	"archive/zip"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

func TestWorkerSelection(t *testing.T) {
	cp := clusterconfig.Node{Name: "kubemaster", Role: clusterconfig.RoleControlPlane, OS: clusterconfig.OsTypeLinux, NodeType: clusterconfig.NodeType("VM"), IpAddress: "172.19.1.100", Username: "remote"}
	winWorker := clusterconfig.Node{Name: "win-host", Role: clusterconfig.RoleWorker, OS: clusterconfig.OsTypeWindows, NodeType: clusterconfig.NodeTypeHost, IpAddress: "172.19.1.1", Username: "admin"}
	genericLinux := clusterconfig.Node{Name: "linux-worker-1", Role: clusterconfig.RoleWorker, OS: clusterconfig.OsTypeLinux, NodeType: clusterconfig.NodeTypeHost, IpAddress: "192.168.1.20", Username: "k2s"}
	preferredDeb13 := clusterconfig.Node{Name: "k2s-nodepkg-debian13", Role: clusterconfig.RoleWorker, OS: clusterconfig.OsTypeLinux, NodeType: clusterconfig.NodeTypeVMExisting, IpAddress: "192.168.1.21", Username: "remote"}
	missingUser := clusterconfig.Node{Name: "broken-worker", Role: clusterconfig.RoleWorker, OS: clusterconfig.OsTypeLinux, NodeType: clusterconfig.NodeTypeHost, IpAddress: "192.168.1.22"}

	t.Run("prefers known CI worker name over generic Linux worker", func(t *testing.T) {
		cfg := &clusterconfig.Cluster{Nodes: []clusterconfig.Node{cp, winWorker, genericLinux, preferredDeb13}}
		got, err := selectTargetLinuxWorker(cfg, "")
		if err != nil {
			t.Fatalf("selectTargetLinuxWorker returned error: %v", err)
		}
		if got.Name != preferredDeb13.Name {
			t.Fatalf("selected worker = %q, want %q", got.Name, preferredDeb13.Name)
		}
	})

	t.Run("falls back to first managed Linux worker when preferred names are absent", func(t *testing.T) {
		cfg := &clusterconfig.Cluster{Nodes: []clusterconfig.Node{cp, winWorker, missingUser, genericLinux}}
		got, err := selectTargetLinuxWorker(cfg, "")
		if err != nil {
			t.Fatalf("selectTargetLinuxWorker returned error: %v", err)
		}
		if got.Name != genericLinux.Name {
			t.Fatalf("selected worker = %q, want %q", got.Name, genericLinux.Name)
		}
	})

	t.Run("honors explicit override case-insensitively and rejects invalid targets", func(t *testing.T) {
		cfg := &clusterconfig.Cluster{Nodes: []clusterconfig.Node{cp, winWorker, genericLinux, preferredDeb13, missingUser}}
		got, err := selectTargetLinuxWorker(cfg, "LINUX-WORKER-1")
		if err != nil || got.Name != genericLinux.Name {
			t.Fatalf("explicit override = (%q, %v), want (%q, nil)", got.Name, err, genericLinux.Name)
		}
		if _, err := selectTargetLinuxWorker(cfg, "does-not-exist"); err == nil {
			t.Fatal("expected error for missing override node")
		}
		if _, err := selectTargetLinuxWorker(cfg, "win-host"); err == nil {
			t.Fatal("expected error for Windows worker override")
		}
		if _, err := selectTargetLinuxWorker(cfg, "broken-worker"); err == nil {
			t.Fatal("expected error for worker missing SSH username")
		}
	})

	t.Run("rejects duplicate explicit override and nil config", func(t *testing.T) {
		if _, err := selectTargetLinuxWorker(nil, ""); err == nil {
			t.Fatal("expected error for nil config")
		}
		dup := &clusterconfig.Cluster{Nodes: []clusterconfig.Node{genericLinux, genericLinux}}
		if _, err := selectTargetLinuxWorker(dup, genericLinux.Name); err == nil {
			t.Fatal("expected error for duplicate worker entry")
		}
	})
}

func TestParseDistroKey(t *testing.T) {
	got, err := parseDistroKey(" Debian \r\n", " 13 \n")
	if err != nil {
		t.Fatalf("parseDistroKey returned error: %v", err)
	}
	if got != "debian13" {
		t.Fatalf("parseDistroKey = %q, want %q", got, "debian13")
	}
	if _, err := parseDistroKey("", "13"); err == nil {
		t.Fatal("expected error for empty distribution ID")
	}
	if _, err := parseDistroKey("Debian", "   "); err == nil {
		t.Fatal("expected error for empty distribution release")
	}
}

func TestDebFilenameToPackageName(t *testing.T) {
	cases := map[string]string{
		"kubernetes/kubelet_1.35.2-1.1_amd64.deb":     "kubelet",
		"packages\\debian13\\buildah\\cri-o_1.35.deb": "cri-o",
		"standalone.deb": "standalone",
	}
	for input, want := range cases {
		if got := debFilenameToPackageName(input); got != want {
			t.Errorf("debFilenameToPackageName(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestNodeDeltaManifestParsing(t *testing.T) {
	// Include a UTF-8 BOM (as written by Windows PowerShell 5.1 Set-Content -Encoding UTF8)
	// and a PowerShell 5.1 single-string list element alongside regular JSON arrays.
	rawJSON := "\xef\xbb\xbf" + `{
  "ManifestVersion": "2.0",
  "DeltaType": "node-package",
  "BasePackage": "old.zip",
  "TargetPackage": "new.zip",
  "Added": "packages/debian13/kubernetes/kubectl_1.35.0_amd64.deb",
  "Changed": ["packages/debian13/kubernetes/kubeadm_1.35.0_amd64.deb", "images/pause.tar"],
  "Removed": [],
  "AddedCount": 1,
  "ChangedCount": 2,
  "RemovedCount": 0,
  "HashAlgorithm": "SHA256",
  "DebianDeltaRelativePath": "packages/debian13",
  "DebianPackageDiff": {
    "Processed": true,
    "Error": null,
    "Added": "kubernetes/kubectl_1.35.0_amd64.deb",
    "Changed": ["kubernetes/kubeadm_1.35.0_amd64.deb"],
    "Removed": [],
    "AddedCount": 1,
    "ChangedCount": 1,
    "RemovedCount": 0
  },
  "ContainerImageDiff": {
    "AddedImages": {},
    "ChangedImages": {
      "pause.tar": { "FullName": "registry.k8s.io/pause:3.10", "ImageId": "abc123def456", "Size": 736000 }
    },
    "RemovedImages": {},
    "AddedCount": 0,
    "ChangedCount": 1,
    "RemovedCount": 0
  }
}`

	manifest, err := parseNodeDeltaManifest([]byte(rawJSON))
	if err != nil {
		t.Fatalf("parseNodeDeltaManifest failed: %v", err)
	}
	if manifest.DeltaType != expectedNodeDeltaType {
		t.Fatalf("DeltaType = %q, want %q", manifest.DeltaType, expectedNodeDeltaType)
	}
	if !slices.Equal([]string(manifest.Added), []string{"packages/debian13/kubernetes/kubectl_1.35.0_amd64.deb"}) {
		t.Fatalf("Added = %v, want single-element list", manifest.Added)
	}
	if !slices.Equal([]string(manifest.DebianPackageDiff.Added), []string{"kubernetes/kubectl_1.35.0_amd64.deb"}) {
		t.Fatalf("DebianPackageDiff.Added = %v", manifest.DebianPackageDiff.Added)
	}
	if manifest.ContainerImageDiff.ChangedImages["pause.tar"].FullName != "registry.k8s.io/pause:3.10" {
		t.Fatalf("unexpected image metadata: %+v", manifest.ContainerImageDiff.ChangedImages["pause.tar"])
	}
}

func TestFullAndDeltaZipValidation(t *testing.T) {
	dir := t.TempDir()

	// Create a full package ZIP using Windows-style backslash entry names to verify normalization.
	fullZip := filepath.Join(dir, "full-winsep.zip")
	f, err := os.Create(fullZip)
	if err != nil {
		t.Fatalf("create full zip: %v", err)
	}
	zw := zip.NewWriter(f)
	entries := map[string]string{
		`packages\debian13\kubernetes\kubelet_1.35.0_amd64.deb`: "kubelet",
		`packages\debian13\kubernetes\kubeadm_1.35.0_amd64.deb`: "kubeadm",
		`packages\debian13\kubernetes\kubectl_1.35.0_amd64.deb`: "kubectl",
		`packages\debian13\buildah\buildah_1.38.0_amd64.deb`:    "buildah",
		`images\pause.tar`: "pause",
	}
	for name, content := range entries {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatalf("create entry %s: %v", name, err)
		}
		if _, err := w.Write([]byte(content)); err != nil {
			t.Fatalf("write entry %s: %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("close zip writer: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close zip file: %v", err)
	}

	fullArchive, err := inspectNodePackageZip(fullZip)
	if err != nil {
		t.Fatalf("inspectNodePackageZip(full) failed: %v", err)
	}
	if err := validateFullNodePackage(fullArchive, "debian13"); err != nil {
		t.Fatalf("validateFullNodePackage failed: %v", err)
	}
	if err := validateFullNodePackage(fullArchive, "debian12"); err == nil {
		t.Fatal("expected validateFullNodePackage to reject wrong OS")
	}

	// Build a valid node delta ZIP with Added, Changed, and Removed entries.
	manifestPayload, err := json.Marshal(nodeDeltaManifest{
		ManifestVersion:         "2.0",
		DeltaType:               "node-package",
		HashAlgorithm:           "SHA256",
		DebianDeltaRelativePath: "packages/debian13",
		Added:                   stringList{"packages/debian13/kubernetes/kubectl_1.35.0_amd64.deb", "images/flannel.tar"},
		Changed:                 stringList{"packages/debian13/kubernetes/kubeadm_1.35.0_amd64.deb"},
		Removed:                 stringList{"packages/debian13/kubernetes/old_1.0.0_amd64.deb", "images/old.tar"},
		AddedCount:              2,
		ChangedCount:            1,
		RemovedCount:            2,
		DebianPackageDiff: debianPackageDiff{
			Processed:    true,
			Added:        stringList{"kubernetes/kubectl_1.35.0_amd64.deb"},
			Changed:      stringList{"kubernetes/kubeadm_1.35.0_amd64.deb"},
			Removed:      stringList{"kubernetes/old_1.0.0_amd64.deb"},
			AddedCount:   1,
			ChangedCount: 1,
			RemovedCount: 1,
		},
		ContainerImageDiff: containerImageDiff{
			AddedImages:   map[string]imageMetadataEntry{"flannel.tar": {FullName: "flannel:v1"}},
			ChangedImages: map[string]imageMetadataEntry{},
			RemovedImages: map[string]imageMetadataEntry{"old.tar": {FullName: "old:v1"}},
			AddedCount:    1,
			ChangedCount:  0,
			RemovedCount:  1,
		},
	})
	if err != nil {
		t.Fatalf("marshal manifest: %v", err)
	}

	deltaZip := filepath.Join(dir, "delta-valid.zip")
	if err := writeZipFixture(deltaZip, map[string][]byte{
		"delta-manifest.json":  append([]byte{0xEF, 0xBB, 0xBF}, manifestPayload...),
		"apply-node-delta.sh":  []byte("#!/usr/bin/env bash\n"),
		"verify-node-delta.sh": []byte("#!/usr/bin/env bash\n"),
		"Apply-Delta.ps1":      []byte("# apply\n"),
		"packages/debian13/kubernetes/kubectl_1.35.0_amd64.deb": []byte("kubectl"),
		"packages/debian13/kubernetes/kubeadm_1.35.0_amd64.deb": []byte("kubeadm"),
		"images/flannel.tar": []byte("flannel"),
		"packages.removed":   []byte("kubernetes/old_1.0.0_amd64.deb\n"),
		"images.removed":     []byte("old.tar\n"),
	}); err != nil {
		t.Fatalf("write delta zip: %v", err)
	}

	deltaArchive, err := inspectNodePackageZip(deltaZip)
	if err != nil {
		t.Fatalf("inspectNodePackageZip(delta) failed: %v", err)
	}
	if err := validateNodeDeltaPackage(deltaArchive, "debian13"); err != nil {
		t.Fatalf("validateNodeDeltaPackage failed: %v", err)
	}

	// Mutating the manifest DeltaType must fail validation.
	deltaArchive.DeltaManifest.DeltaType = "cluster"
	if err := validateNodeDeltaPackage(deltaArchive, "debian13"); err == nil {
		t.Fatal("expected validateNodeDeltaPackage to reject non-node-package DeltaType")
	}
}

func TestDeriveBaseNodePackage(t *testing.T) {
	dir := t.TempDir()
	fullZip := filepath.Join(dir, "full.zip")
	baseZip := filepath.Join(dir, "derived-base.zip")

	if err := writeZipFixture(fullZip, map[string][]byte{
		"packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb": []byte(strings.Repeat("L", 500)),
		"packages/debian13/kubernetes/kubeadm_1.35.0_amd64.deb": []byte(strings.Repeat("A", 300)),
		"packages/debian13/kubernetes/kubectl_1.35.0_amd64.deb": []byte(strings.Repeat("C", 200)),
		"packages/debian13/buildah/buildah_1.38.0_amd64.deb":    []byte(strings.Repeat("B", 100)),
		"images/pause.tar":   []byte(strings.Repeat("p", 50)),
		"images/coredns.tar": []byte(strings.Repeat("d", 150)),
		"images/flannel.tar": []byte(strings.Repeat("f", 400)),
	}); err != nil {
		t.Fatalf("write full zip: %v", err)
	}

	plan, err := deriveBaseNodePackage(fullZip, "debian13", baseZip)
	if err != nil {
		t.Fatalf("deriveBaseNodePackage failed: %v", err)
	}
	if plan.AddedDeb != "kubernetes/kubectl_1.35.0_amd64.deb" {
		t.Fatalf("plan.AddedDeb = %q, want kubectl deb", plan.AddedDeb)
	}
	if plan.ChangedDeb != "kubernetes/kubeadm_1.35.0_amd64.deb" {
		t.Fatalf("plan.ChangedDeb = %q, want kubeadm deb", plan.ChangedDeb)
	}
	if plan.AddedImage != "pause.tar" {
		t.Fatalf("plan.AddedImage = %q, want smallest image pause.tar", plan.AddedImage)
	}
	if plan.ChangedImage != "coredns.tar" {
		t.Fatalf("plan.ChangedImage = %q, want second smallest image coredns.tar", plan.ChangedImage)
	}

	baseArchive, err := inspectNodePackageZip(baseZip)
	if err != nil {
		t.Fatalf("inspect derived base zip: %v", err)
	}
	if _, exists := baseArchive.Entries["packages/debian13/"+plan.AddedDeb]; exists {
		t.Fatalf("derived base should omit AddedDeb %s", plan.AddedDeb)
	}
	if _, exists := baseArchive.Entries["images/"+plan.AddedImage]; exists {
		t.Fatalf("derived base should omit AddedImage %s", plan.AddedImage)
	}
	if _, exists := baseArchive.Entries["packages/debian13/"+plan.ChangedDeb]; !exists {
		t.Fatalf("derived base should keep mutated ChangedDeb %s", plan.ChangedDeb)
	}
	if baseArchive.Entries["packages/debian13/kubernetes/kubelet_1.35.0_amd64.deb"] != 500 {
		t.Fatalf("unchanged kubelet deb size changed unexpectedly")
	}
	if baseArchive.Entries["images/flannel.tar"] != 400 {
		t.Fatalf("unchanged flannel image size changed unexpectedly")
	}
}

func TestUpgradeLogOrdering(t *testing.T) {
	buildLog := func(modeLine string) string {
		return strings.Join([]string{
			"[NodeUpgrade] === Phase 1: Validating inputs ===",
			"[NodeUpgrade] === Phase 2: Locating node and determining OS ===",
			"[NodeUpgrade] === Phase 3: Extracting node package ===",
			"[NodeUpgrade] " + modeLine,
			"[NodeUpgrade] === Phase 4: Detecting OS distribution on node 'node-deb13' ===",
			"[NodeUpgrade] === Phase 5: Cordoning and draining node 'node-deb13' ===",
			"[NodeUpgrade] === Phase 6: Applying upgrade for OS family 'debian' ===",
			"[NodeUpgrade] === Phase 7: Uncordoning node 'node-deb13' ===",
			"[NodeUpgrade] === Phase 8: Waiting for node 'node-deb13' to become Ready ===",
			"[NodeUpgrade] Node 'node-deb13' upgraded successfully.",
		}, "\n")
	}

	fullLog := buildLog("Upgrade mode: FULL (no delta-manifest.json found)")
	deltaLog := buildLog("Upgrade mode: DELTA (node package delta detected)")

	if err := validateUpgradeLogOrdering(fullLog, upgradeModeFull); err != nil {
		t.Fatalf("expected FULL log to pass: %v", err)
	}
	if err := validateUpgradeLogOrdering(deltaLog, upgradeModeDelta); err != nil {
		t.Fatalf("expected DELTA log to pass: %v", err)
	}
	if err := validateUpgradeLogOrdering(fullLog, upgradeModeDelta); err == nil {
		t.Fatal("expected FULL log to fail DELTA mode check")
	}
	if err := validateUpgradeLogOrdering("missing phases", upgradeModeFull); err == nil {
		t.Fatal("expected incomplete log to fail validation")
	}
}

func TestUpgradeObserverLifecycle(t *testing.T) {
	nodeUID := types.UID("worker-uid-1")
	initial := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: "node-deb13", UID: nodeUID, ResourceVersion: "1"},
		Status: corev1.NodeStatus{
			Conditions: []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionTrue}},
		},
	}

	t.Run("accepts cordon -> uncordon -> Ready across watch restart", func(t *testing.T) {
		kubeClient := fake.NewClientset(initial.DeepCopy())
		w1 := watch.NewFake()
		w2 := watch.NewFake()
		watchCount := 0
		kubeClient.PrependWatchReactor("nodes", func(_ k8stesting.Action) (bool, watch.Interface, error) {
			watchCount++
			if watchCount == 1 {
				return true, w1, nil
			}
			return true, w2, nil
		})

		obs, err := observeNodeUpgrade(context.Background(), kubeClient, "node-deb13", nodeUID)
		if err != nil {
			t.Fatalf("observeNodeUpgrade failed: %v", err)
		}
		defer obs.stop()

		cordoned := initial.DeepCopy()
		cordoned.Spec.Unschedulable = true
		w1.Modify(cordoned)
		// Close first watcher to exercise watch reconnection.
		w1.Stop()

		uncordoned := initial.DeepCopy()
		uncordoned.Spec.Unschedulable = false
		w2.Modify(uncordoned)

		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			if obs.verify(nil) == nil {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		if err := obs.verify(uncordoned); err != nil {
			t.Fatalf("expected observer verification to succeed: %v", err)
		}
	})

	t.Run("rejects missing cordon, unexpected deletion, and UID mutation", func(t *testing.T) {
		obs := &upgradeObserver{workerName: "node-deb13", originalUID: nodeUID}
		obs.observe(watch.Modified, initial.DeepCopy())
		if err := obs.verify(initial.DeepCopy()); err == nil {
			t.Fatal("expected error when node was never cordoned")
		}

		delObs := &upgradeObserver{workerName: "node-deb13", originalUID: nodeUID}
		cordoned := initial.DeepCopy()
		cordoned.Spec.Unschedulable = true
		delObs.observe(watch.Modified, cordoned)
		delObs.observe(watch.Deleted, cordoned)
		if err := delObs.verify(initial.DeepCopy()); err == nil || !strings.Contains(err.Error(), "deleted") {
			t.Fatalf("expected deletion error, got: %v", err)
		}

		uidObs := &upgradeObserver{workerName: "node-deb13", originalUID: nodeUID}
		uidObs.observe(watch.Modified, cordoned)
		mutated := initial.DeepCopy()
		mutated.UID = "different-uid"
		uidObs.observe(watch.Modified, mutated)
		if err := uidObs.verify(mutated); err == nil || !strings.Contains(err.Error(), "UID changed") {
			t.Fatalf("expected UID change error, got: %v", err)
		}
	})
}

func TestWorkloadDefinitionsAndPlacement(t *testing.T) {
	workerDep := workerWorkloadDeployment("ns-test", "node-deb13", defaultWorkloadImage)
	if workerDep.Spec.Template.Spec.NodeSelector["kubernetes.io/hostname"] != "node-deb13" {
		t.Fatalf("worker workload missing hostname selector: %+v", workerDep.Spec.Template.Spec.NodeSelector)
	}
	if !slices.ContainsFunc(workerDep.Spec.Template.Spec.Tolerations, func(tol corev1.Toleration) bool {
		return tol.Key == metadataKey && tol.Effect == corev1.TaintEffectNoSchedule
	}) {
		t.Fatal("worker workload must tolerate test NoSchedule taint")
	}

	canaryDep := controlPlaneCanaryDeployment("ns-test", "kubemaster", defaultWorkloadImage)
	if canaryDep.Spec.Template.Spec.NodeSelector["kubernetes.io/hostname"] != "kubemaster" {
		t.Fatalf("canary workload missing control-plane selector: %+v", canaryDep.Spec.Template.Spec.NodeSelector)
	}

	readyPod := func(name, node string, uid types.UID) corev1.Pod {
		return corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: name, UID: uid},
			Spec:       corev1.PodSpec{NodeName: node},
			Status: corev1.PodStatus{
				Phase:      corev1.PodRunning,
				Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}},
			},
		}
	}

	oldPod := readyPod("worker-1", "node-deb13", "uid-old")
	newPod := readyPod("worker-2", "node-deb13", "uid-new")
	if _, err := validateSinglePodOnNode([]corev1.Pod{oldPod}, "node-deb13", "uid-old"); err == nil {
		t.Fatal("expected error when worker pod kept pre-upgrade UID")
	}
	matched, err := validateSinglePodOnNode([]corev1.Pod{newPod}, "node-deb13", "uid-old")
	if err != nil || matched.UID != "uid-new" {
		t.Fatalf("expected rescheduled pod with new UID, got (%v, %v)", matched.UID, err)
	}

	canary := readyPod("canary-1", "kubemaster", "canary-uid")
	if err := validateCanaryPodUnchanged([]corev1.Pod{canary}, "kubemaster", "canary-uid"); err != nil {
		t.Fatalf("expected unchanged canary to pass: %v", err)
	}
	if err := validateCanaryPodUnchanged([]corev1.Pod{canary}, "kubemaster", "other-uid"); err == nil {
		t.Fatal("expected error when canary UID changed")
	}
}

func TestKubeletRestartVerification(t *testing.T) {
	before, err := parseKubeletState("ActiveState=active\nMainPID=1234\nExecMainStartTimestampMonotonic=100000\n")
	if err != nil {
		t.Fatalf("parseKubeletState(before) failed: %v", err)
	}
	after, err := parseKubeletState("ActiveState=active\nMainPID=5678\nExecMainStartTimestampMonotonic=250000\n")
	if err != nil {
		t.Fatalf("parseKubeletState(after) failed: %v", err)
	}
	if err := validateKubeletRestarted(before, after); err != nil {
		t.Fatalf("expected restarted kubelet to pass: %v", err)
	}
	if err := validateKubeletRestarted(before, before); err == nil {
		t.Fatal("expected unchanged kubelet state to fail")
	}
	inactive := after
	inactive.Active = "activating"
	if err := validateKubeletRestarted(before, inactive); err == nil {
		t.Fatal("expected inactive kubelet state to fail")
	}
}

func TestSyntheticNodeHeartbeat(t *testing.T) {
	synthetic := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name: "unmanaged-node-test",
			UID:  types.UID("synthetic-uid-1"),
		},
		Status: corev1.NodeStatus{
			Conditions: []corev1.NodeCondition{
				{Type: corev1.NodeMemoryPressure, Status: corev1.ConditionFalse},
			},
		},
	}
	kubeClient := fake.NewClientset(synthetic.DeepCopy())

	stop, err := startSyntheticNodeHeartbeat(context.Background(), kubeClient, synthetic, 25*time.Millisecond)
	if err != nil {
		t.Fatalf("startSyntheticNodeHeartbeat failed: %v", err)
	}
	defer stop()

	node, err := kubeClient.CoreV1().Nodes().Get(context.Background(), synthetic.Name, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get synthetic node: %v", err)
	}
	if !isNodeReady(node) {
		t.Fatalf("expected synthetic node to be Ready, conditions=%+v", node.Status.Conditions)
	}
	if len(node.Status.Conditions) != 2 {
		t.Fatalf("expected existing non-Ready condition to be preserved, got %+v", node.Status.Conditions)
	}

	lease1, err := kubeClient.CoordinationV1().Leases(nodeLeaseNamespace).Get(context.Background(), synthetic.Name, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("expected kube-node-lease Lease to be created: %v", err)
	}
	if lease1.Spec.RenewTime == nil || lease1.Spec.HolderIdentity == nil || *lease1.Spec.HolderIdentity != synthetic.Name {
		t.Fatalf("unexpected Lease spec: %+v", lease1.Spec)
	}
	if len(lease1.OwnerReferences) != 1 || lease1.OwnerReferences[0].UID != synthetic.UID {
		t.Fatalf("expected Node owner reference on Lease, got %+v", lease1.OwnerReferences)
	}
	firstRenew := lease1.Spec.RenewTime.Time

	deadline := time.Now().Add(2 * time.Second)
	renewed := false
	for time.Now().Before(deadline) {
		lease2, err := kubeClient.CoordinationV1().Leases(nodeLeaseNamespace).Get(context.Background(), synthetic.Name, metav1.GetOptions{})
		if err == nil && lease2.Spec.RenewTime != nil && lease2.Spec.RenewTime.Time.After(firstRenew) {
			renewed = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !renewed {
		t.Fatalf("expected Lease RenewTime to advance beyond %v", firstRenew)
	}

	// Idempotent stop must terminate cleanly without hanging.
	stop()
	stop()
}
