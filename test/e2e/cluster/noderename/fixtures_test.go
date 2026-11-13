// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package noderename

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/validation"
)

func TestWorkerDiscovery(t *testing.T) {
	host := clusterconfig.Node{Name: oldNodeName, OS: "linux", Role: "worker", NodeType: clusterconfig.NodeTypeHost, IpAddress: "192.0.2.2", Username: "admin"}
	vm := host
	vm.NodeType = clusterconfig.NodeTypeVMExisting
	other := host
	other.Name = "another-worker"
	renamed := host
	renamed.Name = newNodeName
	controlPlane := host
	controlPlane.Role = "control-plane"
	windows := host
	windows.OS = "windows"
	unsupported := host
	unsupported.NodeType = "VM-NEW"
	for _, tt := range []struct {
		name   string
		config *clusterconfig.Cluster
		want   clusterconfig.Node
		fail   bool
	}{
		{"bare-metal", &clusterconfig.Cluster{Nodes: []clusterconfig.Node{host}}, host, false},
		{"Hyper-V", &clusterconfig.Cluster{Nodes: []clusterconfig.Node{vm}}, vm, false},
		{"ignore other workers", &clusterconfig.Cluster{Nodes: []clusterconfig.Node{other, host}}, host, false},
		{"missing fixed name", &clusterconfig.Cluster{Nodes: []clusterconfig.Node{other}}, clusterconfig.Node{}, true},
		{"already renamed", &clusterconfig.Cluster{Nodes: []clusterconfig.Node{renamed}}, clusterconfig.Node{}, true},
		{"ambiguous identity", &clusterconfig.Cluster{Nodes: []clusterconfig.Node{host, vm}}, clusterconfig.Node{}, true},
		{"control plane", &clusterconfig.Cluster{Nodes: []clusterconfig.Node{controlPlane}}, clusterconfig.Node{}, true},
		{"Windows", &clusterconfig.Cluster{Nodes: []clusterconfig.Node{windows}}, clusterconfig.Node{}, true},
		{"unsupported type", &clusterconfig.Cluster{Nodes: []clusterconfig.Node{unsupported}}, clusterconfig.Node{}, true},
		{"empty config", &clusterconfig.Cluster{}, clusterconfig.Node{}, true},
		{"missing config", nil, clusterconfig.Node{}, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, err := renameWorker(tt.config)
			if (err != nil) != tt.fail || !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("renameWorker() = %+v, %v; want %+v, failure=%t", got, err, tt.want, tt.fail)
			}
		})
	}
}

func TestReplacementName(t *testing.T) {
	if oldNodeName != "node-deb13" || newNodeName != "node-db13-renamed" {
		t.Fatalf("unexpected fixed rename pair %q -> %q", oldNodeName, newNodeName)
	}
	for _, name := range []string{oldNodeName, newNodeName} {
		if problems := validation.IsDNS1123Label(name); len(problems) != 0 {
			t.Errorf("invalid fixed hostname %q: %v", name, problems)
		}
	}
}

func TestDescriptorFixturesPreserveUnknownFields(t *testing.T) {
	original := []byte(`{"version":42,"nodes":[{"Name":"old","VmName":"unchanged-hyperv-name","Username":"admin","IpAddress":"192.0.2.2","PodCIDR":"172.20.2.0/24","extra":{"keep":true}}]}`)
	for _, bom := range []bool{false, true} {
		input := original
		if bom {
			input = append([]byte{0xef, 0xbb, 0xbf}, original...)
		}
		renamed, err := renamedDescriptor(input, "old", "new")
		if err != nil {
			t.Fatal(err)
		}
		restored, err := renamedDescriptor(renamed, "new", "old")
		if err != nil {
			t.Fatal(err)
		}
		var before, after any
		if err := json.Unmarshal(original, &before); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(restored, &after); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(before, after) {
			t.Fatalf("descriptor round trip lost fields: %s", restored)
		}
		modified, err := appendUnsupportedWorker(input, "unsupported")
		if err != nil {
			t.Fatal(err)
		}
		var config clusterconfig.Cluster
		if err := json.Unmarshal(modified, &config); err != nil {
			t.Fatal(err)
		}
		if len(config.Nodes) != 2 || config.Nodes[1].Name != "unsupported" || config.Nodes[1].NodeType != "UNSUPPORTED-E2E" {
			t.Fatalf("unexpected synthetic descriptor: %s", modified)
		}
	}
}

func TestDescriptorFixturesRejectAmbiguousInput(t *testing.T) {
	for _, input := range []string{
		`invalid`, `{}`, `{"nodes":{}}`, `{"nodes":[{"Name":12}]}`,
		`{"nodes":[{"Name":"other"}]}`,
		`{"nodes":[{"Name":"old"},{"Name":"old"}]}`,
	} {
		if _, err := renamedDescriptor([]byte(input), "old", "new"); err == nil {
			t.Fatalf("accepted invalid or ambiguous descriptor: %s", input)
		}
	}
}

func TestManagedMetadataKeys(t *testing.T) {
	for key, want := range map[string]bool{
		"kubernetes.io/hostname": true, "node.kubernetes.io/not-ready": true,
		"k8s.io/identity": true, "volumes.kubernetes.io/controller-managed-attach-detach": true,
		"team": false, metadataKey: false, "example.org/custom": false,
		"notkubernetes.io/custom": false,
	} {
		if got := managedKey(key); got != want {
			t.Errorf("managedKey(%q) = %t, want %t", key, got, want)
		}
	}
}

func TestRebootBootID(t *testing.T) {
	first := "11111111-2222-3333-4444-555555555555"
	second := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	if err := verifyRebootBootID(first, second); err != nil {
		t.Fatal(err)
	}
	for _, current := range []string{first, "", "ERROR SSH unavailable", "not-a-boot-id"} {
		if err := verifyRebootBootID(first, current); err == nil {
			t.Errorf("accepted unchanged or invalid boot ID %q", current)
		}
	}
	if err := verifyRebootBootID("", second); err == nil {
		t.Error("accepted a missing pre-reboot boot ID")
	}
}

func TestSMBWorkloadDefinition(t *testing.T) {
	writer := markerWriter("test-namespace", "old-worker", "original-data")
	if writer.Spec.NodeName != "old-worker" || writer.Spec.RestartPolicy != corev1.RestartPolicyNever {
		t.Fatal("the marker must be written once from the old worker")
	}
	if !strings.Contains(strings.Join(writer.Spec.Containers[0].Command, " "), "original-data") ||
		writer.Spec.Containers[0].VolumeMounts[0].ReadOnly {
		t.Fatal("the writer must write the original marker to the SMB mount")
	}
	deployment := readerDeployment("test-namespace", "kubemaster", "replacement", "original-data")
	if deployment.Spec.Replicas == nil || *deployment.Spec.Replicas != 3 {
		t.Fatal("expected three reader replicas")
	}
	spec := deployment.Spec.Template.Spec
	if spec.NodeName != "" || spec.NodeSelector["kubernetes.io/os"] != "linux" {
		t.Fatal("readers must be Linux scheduler-managed Pods, not pinned with nodeName")
	}
	terms := spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms
	if len(terms) != 2 || terms[0].MatchExpressions[0].Key != metadataKey ||
		terms[0].MatchExpressions[0].Values[0] != "replacement" || terms[1].MatchFields[0].Values[0] != "kubemaster" {
		t.Fatal("readers must follow the preserved custom label or use the control plane")
	}
	if len(spec.TopologySpreadConstraints) != 1 || spec.TopologySpreadConstraints[0].WhenUnsatisfiable != corev1.DoNotSchedule {
		t.Fatal("pre-rename readers must spread across the worker and control plane")
	}
	reader := spec.Containers[0]
	if !reader.VolumeMounts[0].ReadOnly || reader.ReadinessProbe == nil ||
		!strings.Contains(strings.Join(reader.ReadinessProbe.Exec.Command, " "), "original-data") ||
		strings.Contains(strings.Join(reader.Command, " "), "original-data") {
		t.Fatal("readers must check, not recreate, the original marker")
	}
	if spec.Volumes[0].PersistentVolumeClaim.ClaimName != writer.Spec.Volumes[0].PersistentVolumeClaim.ClaimName {
		t.Fatal("writer and readers must mount the same PVC")
	}
	for _, key := range []string{"node.kubernetes.io/not-ready", "node.kubernetes.io/unreachable"} {
		found := false
		for _, toleration := range spec.Tolerations {
			if toleration.Key == key && toleration.Effect == corev1.TaintEffectNoExecute && toleration.TolerationSeconds == nil {
				found = true
			}
		}
		if !found {
			t.Fatalf("readers need an unbounded %s toleration so reboot alone does not trigger timed eviction", key)
		}
	}
}

func TestSMBReaderPlacement(t *testing.T) {
	readyPod := func(name, node string) corev1.Pod {
		return corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: name},
			Spec:       corev1.PodSpec{NodeName: node},
			Status: corev1.PodStatus{
				Phase:      corev1.PodRunning,
				Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}},
			},
		}
	}
	worker := readyPod("new-worker-reader", newNodeName)
	master1 := readyPod("master-reader-1", "kubemaster")
	master2 := readyPod("master-reader-2", "kubemaster")
	unready := worker.DeepCopy()
	unready.Status.Conditions = nil
	failed := worker.DeepCopy()
	failed.Status.Phase = corev1.PodFailed
	terminating := worker.DeepCopy()
	now := metav1.Now()
	terminating.DeletionTimestamp = &now
	for _, tt := range []struct {
		name  string
		pods  []corev1.Pod
		valid bool
	}{
		{"renamed worker and control plane", []corev1.Pod{worker, master1, master2}, true},
		{"all on kubemaster is insufficient", []corev1.Pod{master1, master2, readyPod("master-reader-3", "kubemaster")}, false},
		{"old Node is not the renamed Node", []corev1.Pod{readyPod("old-reader", oldNodeName), master1, master2}, false},
		{"unrelated worker", []corev1.Pod{readyPod("unrelated-reader", "other-worker"), master1, master2}, false},
		{"missing replica", []corev1.Pod{worker, master1}, false},
		{"missing control plane reader", []corev1.Pod{worker, readyPod("worker-reader-2", newNodeName), readyPod("worker-reader-3", newNodeName)}, false},
		{"unready worker reader", []corev1.Pod{*unready, master1, master2}, false},
		{"failed worker reader", []corev1.Pod{*failed, master1, master2}, false},
		{"terminating worker reader", []corev1.Pod{*terminating, master1, master2}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if err := validateReaderPlacement(tt.pods, newNodeName, "kubemaster"); (err == nil) != tt.valid {
				t.Fatalf("validateReaderPlacement() = %v, want valid=%t", err, tt.valid)
			}
		})
	}
}

func TestSyntheticNodeDaemonPod(t *testing.T) {
	name := "k2s-rename-synthetic"
	pending := corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{OwnerReferences: []metav1.OwnerReference{{
			APIVersion: "apps/v1", Kind: "DaemonSet", Name: "csi-smb-node", Controller: new(true),
		}}},
		Spec: corev1.PodSpec{Affinity: &corev1.Affinity{NodeAffinity: &corev1.NodeAffinity{
			RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{NodeSelectorTerms: []corev1.NodeSelectorTerm{{
				MatchFields: []corev1.NodeSelectorRequirement{{Key: "metadata.name", Operator: corev1.NodeSelectorOpIn, Values: []string{name}}},
			}}},
		}}},
	}
	if !daemonPodTargetsNode(&pending, name) || daemonPodTargetsNode(&pending, oldNodeName) {
		t.Fatal("only the exact synthetic Node's DaemonSet Pod may be cleaned up")
	}
	bound := pending.DeepCopy()
	bound.Spec.NodeName = name
	if !daemonPodTargetsNode(bound, name) || daemonPodTargetsNode(bound, oldNodeName) {
		t.Fatal("bound DaemonSet Pods must match the exact Node name")
	}
	workload := pending.DeepCopy()
	workload.OwnerReferences = nil
	if daemonPodTargetsNode(workload, name) {
		t.Fatal("never delete a user Pod even if its affinity matches the fixture")
	}
	unrestricted := pending.DeepCopy()
	unrestricted.Spec.Affinity = nil
	if daemonPodTargetsNode(unrestricted, name) {
		t.Fatal("never delete a DaemonSet Pod with no exact Node target")
	}
	broad := pending.DeepCopy()
	broad.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms[0].MatchFields[0].Values = []string{name, oldNodeName}
	if daemonPodTargetsNode(broad, name) {
		t.Fatal("never delete a DaemonSet Pod that could target another Node")
	}
	alternative := pending.DeepCopy()
	selector := alternative.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution
	selector.NodeSelectorTerms = append(selector.NodeSelectorTerms, corev1.NodeSelectorTerm{})
	if daemonPodTargetsNode(alternative, name) {
		t.Fatal("never delete a DaemonSet Pod with alternative Node affinity terms")
	}
}

func TestRenameObserverLifecycle(t *testing.T) {
	events := []nodeObservation{
		{uid: "old", unschedulable: true},
		{uid: "old", unschedulable: true, drained: true},
		{uid: "new", ready: true},
		{uid: "old", deleted: true},
	}
	for _, tt := range []struct {
		name   string
		events []nodeObservation
		valid  bool
	}{
		{"complete ordered lifecycle", events, true},
		{"missing cordon", events[1:], false},
		{"missing drain", []nodeObservation{events[0], events[2], events[3]}, false},
		{"missing old deletion", events[:3], false},
		{"delete before readiness", []nodeObservation{events[0], events[1], events[3], events[2]}, false},
		{"Ready before drain", []nodeObservation{events[0], events[2], events[1], events[3]}, false},
		{"partial Node readiness is insufficient", []nodeObservation{events[0], events[1], {uid: "partial", ready: true}, events[3]}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			observer := &renameObserver{events: tt.events}
			if err := observer.validate("old", "new"); (err == nil) != tt.valid {
				t.Fatalf("validate() = %v; valid=%t", err, tt.valid)
			}
		})
	}
	expectedErr := errors.New("Node watch disconnected")
	if err := (&renameObserver{events: events, err: expectedErr}).validate("old", "new"); !errors.Is(err, expectedErr) {
		t.Fatalf("watch failure was not surfaced: %v", err)
	}
	observer := &renameObserver{}
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{UID: "old", Annotations: map[string]string{"k2s.io/rename-drained": "true"}},
		Spec:       corev1.NodeSpec{Unschedulable: true},
	}
	observer.record(node, false)
	if len(observer.events) != 1 || !observer.events[0].drained || !observer.events[0].unschedulable {
		t.Fatal("API observations must preserve the real cordon and completed-drain fields")
	}
}
