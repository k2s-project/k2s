// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package nodeupgrade

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	appsv1 "k8s.io/api/apps/v1"
	coordinationv1 "k8s.io/api/coordination/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/util/retry"
)

const (
	defaultWorkloadImage          = "docker.io/curlimages/curl:8.5.0"
	metadataKey                   = "upgrade.e2e.k2s.io/test"
	workerWorkloadName            = "worker-workload"
	canaryWorkloadName            = "cp-canary"
	nodeLeaseNamespace            = "kube-node-lease"
	syntheticNodeHeartbeatPeriod  = 5 * time.Second
	syntheticNodeLeaseDurationSec = int32(40)
)

// Preferred CI worker names checked first when K2S_NODE_UPGRADE_NODE is unset.
var preferredWorkerNames = []string{"node-deb13", "k2s-nodepkg-debian13"}

type kubeletState struct {
	Active                  string
	MainPID                 string
	StartTimestampMonotonic string
}

func isManagedLinuxWorker(node clusterconfig.Node) bool {
	if node.Role != clusterconfig.RoleWorker || node.OS != clusterconfig.OsTypeLinux {
		return false
	}
	if node.NodeType != clusterconfig.NodeTypeHost && node.NodeType != clusterconfig.NodeTypeVMExisting {
		return false
	}
	return strings.TrimSpace(node.Name) != "" &&
		strings.TrimSpace(node.IpAddress) != "" &&
		strings.TrimSpace(node.Username) != ""
}

func selectTargetLinuxWorker(config *clusterconfig.Cluster, overrideName string) (clusterconfig.Node, error) {
	if config == nil {
		return clusterconfig.Node{}, fmt.Errorf("cluster.json is missing")
	}

	targetName := strings.TrimSpace(overrideName)
	if targetName != "" {
		var matches []clusterconfig.Node
		for _, node := range config.Nodes {
			if strings.EqualFold(node.Name, targetName) {
				matches = append(matches, node)
			}
		}
		if len(matches) == 0 {
			return clusterconfig.Node{}, fmt.Errorf("requested worker %q not found in cluster.json", targetName)
		}
		if len(matches) > 1 {
			return clusterconfig.Node{}, fmt.Errorf("requested worker %q has %d duplicate entries in cluster.json", targetName, len(matches))
		}
		if !isManagedLinuxWorker(matches[0]) {
			return clusterconfig.Node{}, fmt.Errorf("node %q in cluster.json is not a managed Linux worker with SSH details (role=%s, os=%s, type=%s)",
				matches[0].Name, matches[0].Role, matches[0].OS, matches[0].NodeType)
		}
		return matches[0], nil
	}

	for _, preferred := range preferredWorkerNames {
		for _, node := range config.Nodes {
			if strings.EqualFold(node.Name, preferred) && isManagedLinuxWorker(node) {
				return node, nil
			}
		}
	}

	for _, node := range config.Nodes {
		if isManagedLinuxWorker(node) {
			return node, nil
		}
	}

	return clusterconfig.Node{}, fmt.Errorf("no managed Linux worker node (HOST or VM-EXISTING with IP and Username) found in cluster.json")
}

func findLinuxControlPlane(nodes []corev1.Node) (string, error) {
	for _, node := range nodes {
		if node.Labels["kubernetes.io/os"] != "linux" {
			continue
		}
		if _, ok := node.Labels["node-role.kubernetes.io/control-plane"]; ok {
			return node.Name, nil
		}
		if _, ok := node.Labels["node-role.kubernetes.io/master"]; ok {
			return node.Name, nil
		}
	}
	return "", fmt.Errorf("no Linux control-plane Node found in cluster")
}

func isNodeReady(node *corev1.Node) bool {
	return node != nil && slices.ContainsFunc(node.Status.Conditions, func(c corev1.NodeCondition) bool {
		return c.Type == corev1.NodeReady && c.Status == corev1.ConditionTrue
	})
}

func daemonPodTargetsNode(pod *corev1.Pod, nodeName string) bool {
	if !slices.ContainsFunc(pod.OwnerReferences, func(owner metav1.OwnerReference) bool { return owner.Kind == "DaemonSet" }) {
		return false
	}
	if pod.Spec.NodeName == nodeName {
		return true
	}
	if pod.Spec.Affinity == nil || pod.Spec.Affinity.NodeAffinity == nil ||
		pod.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution == nil {
		return false
	}
	for _, term := range pod.Spec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms {
		for _, field := range term.MatchFields {
			if field.Key == "metadata.name" && field.Operator == corev1.NodeSelectorOpIn && slices.Contains(field.Values, nodeName) {
				return true
			}
		}
	}
	return false
}

func workerWorkloadDeployment(namespace, workerName, image string) *appsv1.Deployment {
	labels := map[string]string{"app": workerWorkloadName}
	replicas := int32(1)
	grace := int64(3)
	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: workerWorkloadName, Namespace: namespace},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{MatchLabels: labels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					NodeSelector: map[string]string{
						"kubernetes.io/os":       "linux",
						"kubernetes.io/hostname": workerName,
					},
					Tolerations: []corev1.Toleration{
						{Key: metadataKey, Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
					},
					TerminationGracePeriodSeconds: &grace,
					Containers: []corev1.Container{{
						Name:            "workload",
						Image:           image,
						ImagePullPolicy: corev1.PullIfNotPresent,
						Command:         []string{"sh", "-c", "touch /tmp/ready && while true; do sleep 60; done"},
						ReadinessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{
								Exec: &corev1.ExecAction{Command: []string{"test", "-f", "/tmp/ready"}},
							},
							PeriodSeconds:    2,
							FailureThreshold: 1,
						},
					}},
				},
			},
		},
	}
}

func controlPlaneCanaryDeployment(namespace, controlPlane, image string) *appsv1.Deployment {
	labels := map[string]string{"app": canaryWorkloadName}
	replicas := int32(1)
	grace := int64(3)
	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: canaryWorkloadName, Namespace: namespace},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{MatchLabels: labels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					NodeSelector: map[string]string{
						"kubernetes.io/os":       "linux",
						"kubernetes.io/hostname": controlPlane,
					},
					Tolerations: []corev1.Toleration{
						{Key: "node-role.kubernetes.io/control-plane", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
						{Key: "node-role.kubernetes.io/master", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
					},
					TerminationGracePeriodSeconds: &grace,
					Containers: []corev1.Container{{
						Name:            "canary",
						Image:           image,
						ImagePullPolicy: corev1.PullIfNotPresent,
						Command:         []string{"sh", "-c", "touch /tmp/ready && while true; do sleep 60; done"},
						ReadinessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{
								Exec: &corev1.ExecAction{Command: []string{"test", "-f", "/tmp/ready"}},
							},
							PeriodSeconds:    2,
							FailureThreshold: 1,
						},
					}},
				},
			},
		},
	}
}

func isPodRunningAndReady(pod corev1.Pod) bool {
	if pod.DeletionTimestamp != nil || pod.Status.Phase != corev1.PodRunning {
		return false
	}
	return slices.ContainsFunc(pod.Status.Conditions, func(c corev1.PodCondition) bool {
		return c.Type == corev1.PodReady && c.Status == corev1.ConditionTrue
	})
}

func validateSinglePodOnNode(pods []corev1.Pod, expectedNode string, forbiddenUID types.UID) (corev1.Pod, error) {
	var active []corev1.Pod
	for _, pod := range pods {
		if pod.DeletionTimestamp != nil {
			continue
		}
		active = append(active, pod)
	}
	if len(active) != 1 {
		return corev1.Pod{}, fmt.Errorf("expected exactly 1 active pod on %s, got %d", expectedNode, len(active))
	}
	pod := active[0]
	if pod.Spec.NodeName != expectedNode {
		return corev1.Pod{}, fmt.Errorf("pod %s is scheduled on %q, expected %q", pod.Name, pod.Spec.NodeName, expectedNode)
	}
	if !isPodRunningAndReady(pod) {
		return corev1.Pod{}, fmt.Errorf("pod %s on %s is not Running and Ready (phase=%s)", pod.Name, expectedNode, pod.Status.Phase)
	}
	if forbiddenUID != "" && pod.UID == forbiddenUID {
		return corev1.Pod{}, fmt.Errorf("pod %s on %s kept pre-upgrade UID %s; expected drain eviction and rescheduling", pod.Name, expectedNode, pod.UID)
	}
	return pod, nil
}

func validateCanaryPodUnchanged(pods []corev1.Pod, controlPlane string, expectedUID types.UID) error {
	pod, err := validateSinglePodOnNode(pods, controlPlane, "")
	if err != nil {
		return fmt.Errorf("control-plane canary check failed: %w", err)
	}
	if pod.UID != expectedUID {
		return fmt.Errorf("control-plane canary pod UID changed from %s to %s during worker upgrade", expectedUID, pod.UID)
	}
	return nil
}

func parseKubeletState(raw string) (kubeletState, error) {
	var state kubeletState
	for _, line := range strings.Split(raw, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		k, v, ok := strings.Cut(trimmed, "=")
		if !ok {
			continue
		}
		switch k {
		case "ActiveState":
			state.Active = strings.TrimSpace(v)
		case "MainPID":
			state.MainPID = strings.TrimSpace(v)
		case "ExecMainStartTimestampMonotonic":
			state.StartTimestampMonotonic = strings.TrimSpace(v)
		}
	}
	if state.Active == "" || state.StartTimestampMonotonic == "" {
		return kubeletState{}, fmt.Errorf("incomplete kubelet state output: %q", raw)
	}
	return state, nil
}

func validateKubeletRestarted(before, after kubeletState) error {
	if after.Active != "active" {
		return fmt.Errorf("kubelet ActiveState after upgrade is %q, want \"active\"", after.Active)
	}
	if after.StartTimestampMonotonic == before.StartTimestampMonotonic &&
		(after.MainPID == "" || after.MainPID == before.MainPID) {
		return fmt.Errorf("kubelet did not restart during upgrade (StartTimestampMonotonic=%s, MainPID=%s)",
			after.StartTimestampMonotonic, after.MainPID)
	}
	return nil
}

// upgradeObserver watches Kubernetes Node API events during a live node upgrade
// to verify the exact in-place transition sequence: cordoned -> uncordoned -> Ready,
// without deleting the Node or mutating its UID.
type upgradeObserver struct {
	workerName  string
	originalUID types.UID
	cancel      context.CancelFunc
	done        chan struct{}

	mu                    sync.Mutex
	sawCordoned           bool
	sawUncordoned         bool
	sawReadyAfterUncordon bool
	sawDeleted            bool
	uidChanged            bool
	observedUID           types.UID
	watchErr              error
}

func observeNodeUpgrade(ctx context.Context, kubeClient kubernetes.Interface, workerName string, originalUID types.UID) (*upgradeObserver, error) {
	list, err := kubeClient.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("list nodes before watching upgrade: %w", err)
	}
	watchCtx, cancel := context.WithCancel(ctx)
	watcher, err := kubeClient.CoreV1().Nodes().Watch(watchCtx, metav1.ListOptions{ResourceVersion: list.ResourceVersion})
	if err != nil {
		cancel()
		return nil, fmt.Errorf("start node watch before upgrade: %w", err)
	}
	obs := &upgradeObserver{
		workerName:  workerName,
		originalUID: originalUID,
		cancel:      cancel,
		done:        make(chan struct{}),
	}
	go obs.run(watchCtx, kubeClient, watcher)
	return obs, nil
}

func (o *upgradeObserver) run(ctx context.Context, kubeClient kubernetes.Interface, watcher watch.Interface) {
	defer close(o.done)
	defer func() {
		if watcher != nil {
			watcher.Stop()
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return
		case event, ok := <-watcher.ResultChan():
			if !ok {
				watcher.Stop()
				watcher = nil
				if ctx.Err() != nil {
					return
				}
				list, err := kubeClient.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
				if err != nil {
					if ctx.Err() == nil {
						o.recordErr(fmt.Errorf("re-list nodes after watch closed: %w", err))
					}
					return
				}
				for i := range list.Items {
					o.observe(watch.Modified, &list.Items[i])
				}
				watcher, err = kubeClient.CoreV1().Nodes().Watch(ctx, metav1.ListOptions{ResourceVersion: list.ResourceVersion})
				if err != nil {
					if ctx.Err() == nil {
						o.recordErr(fmt.Errorf("restart node watch: %w", err))
					}
					return
				}
				continue
			}
			if event.Type == watch.Error || event.Type == watch.Bookmark {
				continue
			}
			node, ok := event.Object.(*corev1.Node)
			if !ok || node == nil {
				continue
			}
			o.observe(event.Type, node)
		}
	}
}

func (o *upgradeObserver) observe(eventType watch.EventType, node *corev1.Node) {
	if node.Name != o.workerName {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()

	if eventType == watch.Deleted {
		o.sawDeleted = true
		return
	}
	if o.originalUID != "" && node.UID != "" && node.UID != o.originalUID {
		o.uidChanged = true
		o.observedUID = node.UID
	}
	if node.Spec.Unschedulable {
		o.sawCordoned = true
		return
	}
	if o.sawCordoned && !node.Spec.Unschedulable {
		o.sawUncordoned = true
		if isNodeReady(node) {
			o.sawReadyAfterUncordon = true
		}
	}
}

func (o *upgradeObserver) recordErr(err error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.watchErr == nil {
		o.watchErr = err
	}
}

func (o *upgradeObserver) stop() {
	o.cancel()
	select {
	case <-o.done:
	case <-time.After(10 * time.Second):
	}
}

func (o *upgradeObserver) verify(finalNode *corev1.Node) error {
	if finalNode != nil {
		o.observe(watch.Modified, finalNode)
	}
	o.mu.Lock()
	defer o.mu.Unlock()

	if o.watchErr != nil {
		return o.watchErr
	}
	if o.sawDeleted {
		return fmt.Errorf("node %s was unexpectedly deleted during in-place upgrade", o.workerName)
	}
	if o.uidChanged {
		return fmt.Errorf("node %s UID changed from %s to %s during in-place upgrade", o.workerName, o.originalUID, o.observedUID)
	}
	if !o.sawCordoned {
		return fmt.Errorf("node %s was never observed cordoned (Unschedulable=true) during upgrade", o.workerName)
	}
	if !o.sawUncordoned {
		return fmt.Errorf("node %s was never observed uncordoned (Unschedulable=false) after cordon", o.workerName)
	}
	if !o.sawReadyAfterUncordon {
		return fmt.Errorf("node %s was never observed Ready after uncordon", o.workerName)
	}
	return nil
}

func upsertReadyCondition(conditions []corev1.NodeCondition, now, transitionTime metav1.Time) []corev1.NodeCondition {
	updated := corev1.NodeCondition{
		Type:               corev1.NodeReady,
		Status:             corev1.ConditionTrue,
		LastHeartbeatTime:  now,
		LastTransitionTime: transitionTime,
		Reason:             "KubeletReady",
		Message:            "synthetic node ready for upgrade validation",
	}
	result := make([]corev1.NodeCondition, 0, len(conditions)+1)
	replaced := false
	for _, c := range conditions {
		if c.Type == corev1.NodeReady {
			result = append(result, updated)
			replaced = true
		} else {
			result = append(result, c)
		}
	}
	if !replaced {
		result = append(result, updated)
	}
	return result
}

func refreshSyntheticNodeReady(ctx context.Context, kubeClient kubernetes.Interface, nodeName string, nodeUID types.UID, transitionTime metav1.Time) error {
	now := metav1.Now()
	if err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		current, err := kubeClient.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
		if err != nil {
			return err
		}
		current.Status.Conditions = upsertReadyCondition(current.Status.Conditions, now, transitionTime)
		_, err = kubeClient.CoreV1().Nodes().UpdateStatus(ctx, current, metav1.UpdateOptions{})
		return err
	}); err != nil {
		return fmt.Errorf("update Ready status on synthetic Node %s: %w", nodeName, err)
	}

	leaseDuration := syntheticNodeLeaseDurationSec
	microNow := metav1.NewMicroTime(now.Time)
	if err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		leases := kubeClient.CoordinationV1().Leases(nodeLeaseNamespace)
		existing, err := leases.Get(ctx, nodeName, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			lease := &coordinationv1.Lease{
				ObjectMeta: metav1.ObjectMeta{
					Name:      nodeName,
					Namespace: nodeLeaseNamespace,
				},
				Spec: coordinationv1.LeaseSpec{
					HolderIdentity:       &nodeName,
					LeaseDurationSeconds: &leaseDuration,
					RenewTime:            &microNow,
				},
			}
			if nodeUID != "" {
				lease.OwnerReferences = []metav1.OwnerReference{{
					APIVersion: corev1.SchemeGroupVersion.String(),
					Kind:       "Node",
					Name:       nodeName,
					UID:        nodeUID,
				}}
			}
			_, createErr := leases.Create(ctx, lease, metav1.CreateOptions{})
			if apierrors.IsAlreadyExists(createErr) {
				existing, err = leases.Get(ctx, nodeName, metav1.GetOptions{})
				if err != nil {
					return err
				}
			} else {
				return createErr
			}
		} else if err != nil {
			return err
		}

		existing.Spec.HolderIdentity = &nodeName
		existing.Spec.LeaseDurationSeconds = &leaseDuration
		existing.Spec.RenewTime = &microNow
		_, err = leases.Update(ctx, existing, metav1.UpdateOptions{})
		return err
	}); err != nil {
		return fmt.Errorf("renew Lease for synthetic Node %s: %w", nodeName, err)
	}

	return nil
}

// startSyntheticNodeHeartbeat marks a synthetic Node Ready and periodically
// renews both its Ready condition LastHeartbeatTime and kube-node-lease Lease
// until stop is called, preventing Kubernetes' node lifecycle controller from
// flipping the node to Unknown before validation commands complete.
func startSyntheticNodeHeartbeat(ctx context.Context, kubeClient kubernetes.Interface, node *corev1.Node, interval time.Duration) (func(), error) {
	if node == nil || node.Name == "" {
		return nil, fmt.Errorf("synthetic node is required")
	}
	if interval <= 0 {
		interval = syntheticNodeHeartbeatPeriod
	}
	transitionTime := metav1.Now()
	if err := refreshSyntheticNodeReady(ctx, kubeClient, node.Name, node.UID, transitionTime); err != nil {
		return nil, err
	}

	hbCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-hbCtx.Done():
				return
			case <-ticker.C:
				_ = refreshSyntheticNodeReady(hbCtx, kubeClient, node.Name, node.UID, transitionTime)
			}
		}
	}()

	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			cancel()
			<-done
		})
	}
	return stop, nil
}
