// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package noderename

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	addonstatus "github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/util/retry"
)

const (
	migrationImage    = "docker.io/curlimages/curl:8.5.0"
	migrationReplicas = int32(3)
	markerPath        = "/mnt/smb/rename-marker"
	workloadTimeout   = 10 * time.Minute
)

var bootIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func ensureLinuxSMB(ctx SpecContext) string {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", "storage", "smb", "-o", "json")
	var status addonstatus.AddonPrintStatus
	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	if !*status.Enabled {
		suite.K2sCli().MustExec(ctx, "addons", "enable", "storage", "smb", "-t", "linux", "-o")
		DeferCleanup(func(ctx SpecContext) {
			// Never delete pre-existing share folders when undoing the test's addon enable.
			suite.K2sCli().MustExec(ctx, "addons", "disable", "storage", "smb", "-k", "-o")
		}, NodeTimeout(20*time.Minute))
		output = suite.K2sCli().MustExec(ctx, "addons", "status", "storage", "smb", "-o", "json")
		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
	}
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	linuxHost := slices.ContainsFunc(status.Props, func(prop addonstatus.AddonStatusProp) bool {
		return prop.Name == "SmbHostType" && prop.Value == "linux"
	})
	Expect(linuxHost).To(BeTrue(), "storage smb must use Linux hosting; the suite will not replace an existing Windows-hosted addon")
	classes, err := client.StorageV1().StorageClasses().List(ctx, metav1.ListOptions{})
	Expect(err).NotTo(HaveOccurred())
	names := []string{}
	for _, class := range classes.Items {
		if class.Provisioner == "smb.csi.k8s.io" {
			names = append(names, class.Name)
		}
	}
	sort.Strings(names)
	Expect(names).NotTo(BeEmpty(), "Linux SMB must provide a StorageClass")
	if slices.Contains(names, "smb") {
		return "smb"
	}
	return names[0]
}

func rebootWorker(ctx SpecContext, worker clusterconfig.Node, newName string) {
	bootID := remote(ctx, worker, "cat /proc/sys/kernel/random/boot_id")
	Expect(bootIDPattern.MatchString(bootID)).To(BeTrue(), "read a valid kernel boot ID before requesting reboot")
	By("scheduling a real Linux reboot after changing the hostname")
	remote(ctx, worker, "sudo -n systemd-run --unit=k2s-node-rename-e2e-reboot --on-active=3s /usr/bin/systemctl reboot")
	By("waiting for SSH to return with a different kernel boot ID")
	Eventually(func() (string, error) {
		output, code := suite.K2sCli().Exec(ctx, "node", "exec",
			"--ip-addr", worker.IpAddress, "--username", worker.Username, "--timeout", "5s",
			"--command", "cat /proc/sys/kernel/random/boot_id", "--raw")
		if code != 0 {
			return "", fmt.Errorf("SSH is not available after reboot (exit %d): %s", code, output)
		}
		current := strings.TrimSpace(output)
		if err := verifyRebootBootID(bootID, current); err != nil {
			return "", err
		}
		return current, nil
	}, 5*time.Minute, 5*time.Second).ShouldNot(BeEmpty())
	Expect(remote(ctx, worker, "hostname")).To(Equal(newName))
}

func verifyRebootBootID(before, after string) error {
	if !bootIDPattern.MatchString(before) || !bootIDPattern.MatchString(after) {
		return fmt.Errorf("expected valid kernel boot IDs, got %q -> %q", before, after)
	}
	if before == after {
		return fmt.Errorf("worker has not completed its reboot; boot ID is still %q", after)
	}
	return nil
}

type migrationWorkload struct {
	namespace    string
	controlPlane string
	marker       string
	pvc          *corev1.PersistentVolumeClaim
	pv           *corev1.PersistentVolume
	beforePods   []corev1.Pod
	cleanup      func(SpecContext)
}

func createMigrationWorkload(ctx SpecContext, worker clusterconfig.Node, newName, storageClass string) *migrationWorkload {
	fixture := &migrationWorkload{
		namespace: newName + "-data", marker: uniqueName(),
		controlPlane: suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(),
	}
	controlPlane := getNode(ctx, fixture.controlPlane)
	Expect(isReady(controlPlane)).To(BeTrue())
	Expect(controlPlane.Spec.Unschedulable).To(BeFalse(), "the control plane must be schedulable for failover checks")
	source, err := client.StorageV1().StorageClasses().Get(ctx, storageClass, metav1.GetOptions{})
	Expect(err).NotTo(HaveOccurred())
	Expect(source.Parameters["csi.storage.k8s.io/provisioner-secret-name"]).NotTo(BeEmpty(), "SMB must dynamically provision isolated PV subdirectories")
	parameters := maps.Clone(source.Parameters)
	// Use the CSI driver's unique PV-name default, not an inherited fixed share subdirectory.
	for key := range parameters {
		if strings.EqualFold(key, "subDir") || strings.EqualFold(key, "onDelete") {
			delete(parameters, key)
		}
	}
	parameters["onDelete"] = "delete"
	className := fixture.namespace + "-smb"
	deletePolicy := corev1.PersistentVolumeReclaimDelete
	binding := storagev1.VolumeBindingImmediate
	_, err = client.StorageV1().StorageClasses().Create(ctx, &storagev1.StorageClass{
		ObjectMeta:  metav1.ObjectMeta{Name: className},
		Provisioner: source.Provisioner, Parameters: parameters, MountOptions: source.MountOptions,
		ReclaimPolicy: &deletePolicy, VolumeBindingMode: &binding,
	}, metav1.CreateOptions{})
	Expect(err).NotTo(HaveOccurred())
	DeferCleanup(func(ctx SpecContext) {
		Expect(client.StorageV1().StorageClasses().Delete(ctx, className, metav1.DeleteOptions{})).To(Succeed())
	})
	_, err = client.CoreV1().Namespaces().Create(ctx, &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{Name: fixture.namespace},
	}, metav1.CreateOptions{})
	Expect(err).NotTo(HaveOccurred())
	cleaned := false
	fixture.cleanup = func(ctx SpecContext) {
		if cleaned {
			return
		}
		err := client.CoreV1().Namespaces().Delete(ctx, fixture.namespace, metav1.DeleteOptions{})
		Expect(err == nil || apierrors.IsNotFound(err)).To(BeTrue(), "delete workload namespace: %v", err)
		Eventually(func() error {
			_, err := client.CoreV1().Namespaces().Get(ctx, fixture.namespace, metav1.GetOptions{})
			if !apierrors.IsNotFound(err) {
				return fmt.Errorf("waiting for namespace %s deletion: %v", fixture.namespace, err)
			}
			if fixture.pv != nil {
				_, err = client.CoreV1().PersistentVolumes().Get(ctx, fixture.pv.Name, metav1.GetOptions{})
				if !apierrors.IsNotFound(err) {
					return fmt.Errorf("waiting for test PV %s deletion: %v", fixture.pv.Name, err)
				}
			}
			return nil
		}, workloadTimeout, 2*time.Second).Should(Succeed())
		cleaned = true
	}
	DeferCleanup(fixture.cleanup, NodeTimeout(12*time.Minute))
	_, err = client.CoreV1().PersistentVolumeClaims(fixture.namespace).Create(ctx, &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: "smb-data"},
		Spec: corev1.PersistentVolumeClaimSpec{
			StorageClassName: &className, AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteMany},
			Resources: corev1.VolumeResourceRequirements{Requests: corev1.ResourceList{corev1.ResourceStorage: resource.MustParse("1Gi")}},
		},
	}, metav1.CreateOptions{})
	Expect(err).NotTo(HaveOccurred())
	Eventually(func() error {
		pvc, err := client.CoreV1().PersistentVolumeClaims(fixture.namespace).Get(ctx, "smb-data", metav1.GetOptions{})
		if err != nil {
			return err
		}
		if pvc.Status.Phase != corev1.ClaimBound || pvc.Spec.VolumeName == "" {
			return fmt.Errorf("SMB PVC is not Bound: %s", pvc.Status.Phase)
		}
		fixture.pvc = pvc
		return nil
	}, workloadTimeout, 2*time.Second).Should(Succeed())
	fixture.pv, err = client.CoreV1().PersistentVolumes().Get(ctx, fixture.pvc.Spec.VolumeName, metav1.GetOptions{})
	Expect(err).NotTo(HaveOccurred())
	Expect(fixture.pv.Spec.CSI).NotTo(BeNil())
	Expect(fixture.pv.Spec.CSI.Driver).To(Equal("smb.csi.k8s.io"))
	By("writing a unique marker to the SMB PV from the old worker")
	_, err = client.CoreV1().Pods(fixture.namespace).Create(ctx, markerWriter(fixture.namespace, worker.Name, fixture.marker), metav1.CreateOptions{})
	Expect(err).NotTo(HaveOccurred())
	Eventually(func() error {
		pod, err := client.CoreV1().Pods(fixture.namespace).Get(ctx, "write-marker", metav1.GetOptions{})
		if err != nil {
			return err
		}
		if pod.Status.Phase != corev1.PodSucceeded {
			return fmt.Errorf("SMB marker writer has not succeeded: %s", pod.Status.Phase)
		}
		return nil
	}, workloadTimeout, 2*time.Second).Should(Succeed())
	Expect(strings.TrimSpace(suite.Kubectl().MustExec(ctx, "logs", "-n", fixture.namespace, "write-marker"))).To(Equal(fixture.marker))
	Expect(client.CoreV1().Pods(fixture.namespace).Delete(ctx, "write-marker", metav1.DeleteOptions{})).To(Succeed())
	By("starting three SMB reader replicas spread across the old worker and control plane")
	_, err = client.AppsV1().Deployments(fixture.namespace).Create(ctx,
		readerDeployment(fixture.namespace, fixture.controlPlane, newName, fixture.marker), metav1.CreateOptions{})
	Expect(err).NotTo(HaveOccurred())
	fixture.beforePods = fixture.waitForReaders(ctx, worker.Name, true)
	return fixture
}

func markerWriter(namespace, nodeName, marker string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "write-marker", Namespace: namespace},
		Spec: corev1.PodSpec{
			NodeName: nodeName, RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{{
				Name: "writer", Image: migrationImage, ImagePullPolicy: corev1.PullIfNotPresent,
				Command:      []string{"sh", "-c", fmt.Sprintf("set -eu; printf '%%s' '%s' > %s; sync; cat %s", marker, markerPath, markerPath)},
				VolumeMounts: []corev1.VolumeMount{{Name: "data", MountPath: "/mnt/smb"}},
			}},
			Volumes: smbVolumes(),
		},
	}
}

func readerDeployment(namespace, controlPlane, labelValue, marker string) *appsv1.Deployment {
	labels := map[string]string{"app": "rename-smb-readers"}
	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: "readers", Namespace: namespace},
		Spec: appsv1.DeploymentSpec{
			Replicas: new(migrationReplicas), Selector: &metav1.LabelSelector{MatchLabels: labels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					NodeSelector: map[string]string{"kubernetes.io/os": "linux"},
					Affinity: &corev1.Affinity{NodeAffinity: &corev1.NodeAffinity{
						RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{NodeSelectorTerms: []corev1.NodeSelectorTerm{
							{MatchExpressions: []corev1.NodeSelectorRequirement{{Key: metadataKey, Operator: corev1.NodeSelectorOpIn, Values: []string{labelValue}}}},
							{MatchFields: []corev1.NodeSelectorRequirement{{Key: "metadata.name", Operator: corev1.NodeSelectorOpIn, Values: []string{controlPlane}}}},
						}},
					}},
					Tolerations: []corev1.Toleration{
						{Key: metadataKey, Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
						{Key: "node-role.kubernetes.io/control-plane", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
						{Key: "node-role.kubernetes.io/master", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
						{Key: "node.kubernetes.io/not-ready", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoExecute},
						{Key: "node.kubernetes.io/unreachable", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoExecute},
					},
					TopologySpreadConstraints: []corev1.TopologySpreadConstraint{{
						MaxSkew: 1, TopologyKey: "kubernetes.io/hostname", WhenUnsatisfiable: corev1.DoNotSchedule,
						LabelSelector: &metav1.LabelSelector{MatchLabels: labels},
					}},
					TerminationGracePeriodSeconds: new(int64(5)),
					Containers: []corev1.Container{{
						Name: "reader", Image: migrationImage, ImagePullPolicy: corev1.PullIfNotPresent,
						Command: []string{"sh", "-c", "while true; do sleep 60; done"},
						ReadinessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{Exec: &corev1.ExecAction{
								Command: []string{"sh", "-c", fmt.Sprintf("test \"$(cat %s)\" = '%s'", markerPath, marker)},
							}},
							PeriodSeconds: 3, FailureThreshold: 1,
						},
						VolumeMounts: []corev1.VolumeMount{{Name: "data", MountPath: "/mnt/smb", ReadOnly: true}},
					}},
					Volumes: smbVolumes(),
				},
			},
		},
	}
}

func smbVolumes() []corev1.Volume {
	return []corev1.Volume{{Name: "data", VolumeSource: corev1.VolumeSource{
		PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: "smb-data"},
	}}}
}

func (fixture *migrationWorkload) waitForReaders(ctx SpecContext, workerName string, requireWorker bool) []corev1.Pod {
	var ready []corev1.Pod
	Eventually(func() error {
		pods, err := client.CoreV1().Pods(fixture.namespace).List(ctx, metav1.ListOptions{LabelSelector: "app=rename-smb-readers"})
		if err != nil {
			return err
		}
		ready = nil
		onWorker, onControlPlane := false, false
		for _, pod := range pods.Items {
			if pod.DeletionTimestamp != nil {
				continue
			}
			if pod.Spec.NodeName != workerName && pod.Spec.NodeName != fixture.controlPlane {
				return fmt.Errorf("reader %s is assigned to unexpected Node %q", pod.Name, pod.Spec.NodeName)
			}
			if pod.Status.Phase != corev1.PodRunning || !slices.ContainsFunc(pod.Status.Conditions, func(condition corev1.PodCondition) bool {
				return condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue
			}) {
				return fmt.Errorf("reader %s on %s is not Running and Ready", pod.Name, pod.Spec.NodeName)
			}
			ready = append(ready, pod)
			onWorker = onWorker || pod.Spec.NodeName == workerName
			onControlPlane = onControlPlane || pod.Spec.NodeName == fixture.controlPlane
		}
		if len(ready) != int(migrationReplicas) || (requireWorker && (!onWorker || !onControlPlane)) {
			return fmt.Errorf("ready readers=%d, reader on %s=%t, reader on control plane=%t; require %d replicas", len(ready), workerName, onWorker, onControlPlane, migrationReplicas)
		}
		return nil
	}, workloadTimeout, 2*time.Second).Should(Succeed())
	return ready
}

func (fixture *migrationWorkload) verifyAfterRename(ctx SpecContext, oldName, newName string, unschedulable bool) {
	if unschedulable {
		By("allowing all replicas to fail over to the control plane while the replacement intentionally stays cordoned")
		Expect(retry.RetryOnConflict(retry.DefaultRetry, func() error {
			deployment, err := client.AppsV1().Deployments(fixture.namespace).Get(ctx, "readers", metav1.GetOptions{})
			if err != nil {
				return err
			}
			deployment.Spec.Template.Spec.TopologySpreadConstraints = nil
			_, err = client.AppsV1().Deployments(fixture.namespace).Update(ctx, deployment, metav1.UpdateOptions{})
			return err
		})).To(Succeed())
	}
	By("verifying three Running replicas and replacement Pod UIDs after migration")
	after := fixture.waitForReaders(ctx, newName, !unschedulable)
	if unschedulable {
		for _, pod := range after {
			Expect(pod.Spec.NodeName).To(Equal(fixture.controlPlane), "the cordoned replacement must not receive reader Pods")
		}
	}
	for _, pod := range fixture.beforePods {
		if pod.Spec.NodeName != oldName {
			continue
		}
		Expect(slices.ContainsFunc(after, func(current corev1.Pod) bool { return current.UID == pod.UID })).To(BeFalse(), "old worker Pod %s must have been replaced", pod.Name)
		Eventually(func() error {
			current, err := client.CoreV1().Pods(fixture.namespace).Get(ctx, pod.Name, metav1.GetOptions{})
			if apierrors.IsNotFound(err) {
				return nil
			}
			if err != nil {
				return err
			}
			if current.UID == pod.UID {
				return fmt.Errorf("old worker Pod %s (UID %s) still exists after drain", pod.Name, pod.UID)
			}
			return nil
		}, workloadTimeout, 2*time.Second).Should(Succeed())
	}
	By("reading the original marker from every replacement SMB reader without rewriting it")
	for _, pod := range after {
		output := suite.Kubectl().MustExec(ctx, "exec", "-n", fixture.namespace, pod.Name, "-c", "reader", "--", "cat", markerPath)
		Expect(strings.TrimSpace(output)).To(Equal(fixture.marker))
		GinkgoWriter.Printf("SMB reader %s (UID %s) is Running on %s and read the original marker\n", pod.Name, pod.UID, pod.Spec.NodeName)
	}
	pvc, err := client.CoreV1().PersistentVolumeClaims(fixture.namespace).Get(ctx, fixture.pvc.Name, metav1.GetOptions{})
	Expect(err).NotTo(HaveOccurred())
	Expect(pvc.UID).To(Equal(fixture.pvc.UID))
	Expect(pvc.Status.Phase).To(Equal(corev1.ClaimBound))
	Expect(pvc.Spec.VolumeName).To(Equal(fixture.pv.Name))
	pv, err := client.CoreV1().PersistentVolumes().Get(ctx, fixture.pv.Name, metav1.GetOptions{})
	Expect(err).NotTo(HaveOccurred())
	Expect(pv.UID).To(Equal(fixture.pv.UID))
	Expect(pv.Spec.CSI).NotTo(BeNil())
	Expect(pv.Spec.CSI.VolumeHandle).To(Equal(fixture.pv.Spec.CSI.VolumeHandle))
}

type nodeObservation struct {
	uid           types.UID
	ready         bool
	unschedulable bool
	drained       bool
	deleted       bool
}

type renameObserver struct {
	mu     sync.Mutex
	events []nodeObservation
	err    error
}

func observeRename(ctx SpecContext) *renameObserver {
	list, err := client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	Expect(err).NotTo(HaveOccurred())
	watchCtx, cancel := context.WithCancel(ctx)
	stream, err := client.CoreV1().Nodes().Watch(watchCtx, metav1.ListOptions{ResourceVersion: list.ResourceVersion})
	Expect(err).NotTo(HaveOccurred())
	observer := &renameObserver{}
	for _, node := range list.Items {
		observer.record(&node, false)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for event := range stream.ResultChan() {
			if event.Type == watch.Bookmark {
				continue
			}
			observer.mu.Lock()
			if event.Type == watch.Error {
				observer.err = apierrors.FromObject(event.Object)
				observer.mu.Unlock()
				return
			}
			observer.mu.Unlock()
			node, ok := event.Object.(*corev1.Node)
			if !ok {
				observer.mu.Lock()
				observer.err = fmt.Errorf("unexpected Node watch object %T", event.Object)
				observer.mu.Unlock()
				return
			}
			observer.record(node, event.Type == watch.Deleted)
		}
		if watchCtx.Err() == nil {
			observer.mu.Lock()
			observer.err = fmt.Errorf("Node watch closed before rename verification completed")
			observer.mu.Unlock()
		}
	}()
	DeferCleanup(func() {
		cancel()
		stream.Stop()
		<-done
	})
	return observer
}

func (observer *renameObserver) record(node *corev1.Node, deleted bool) {
	observer.mu.Lock()
	defer observer.mu.Unlock()
	observer.events = append(observer.events, nodeObservation{
		uid: node.UID, ready: isReady(node), unschedulable: node.Spec.Unschedulable,
		drained: node.Annotations["k2s.io/rename-drained"] == "true", deleted: deleted,
	})
}

func (observer *renameObserver) validate(oldUID, newUID types.UID) error {
	observer.mu.Lock()
	defer observer.mu.Unlock()
	if observer.err != nil {
		return observer.err
	}
	cordoned, drained, ready, retired := -1, -1, -1, -1
	for index, event := range observer.events {
		if event.uid == oldUID {
			if event.unschedulable && !event.deleted && cordoned < 0 {
				cordoned = index
			}
			if event.drained && event.unschedulable && !event.deleted && drained < 0 {
				drained = index
			}
			if event.deleted {
				retired = index
			}
		}
		if event.uid == newUID && event.ready && !event.deleted && ready < 0 {
			ready = index
		}
	}
	if cordoned < 0 || drained <= cordoned || ready <= drained || retired <= ready {
		return fmt.Errorf("expected cordon -> completed drain -> replacement Ready -> old deletion; observed event indices %d -> %d -> %d -> %d", cordoned, drained, ready, retired)
	}
	return nil
}
