// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package noderename

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/test/framework"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/util/retry"
)

const (
	metadataKey = "rename.e2e.k2s.io/test"
	oldNodeName = "k2s-nodepkg-debian13"
	newNodeName = "node-db13-renamed"
)

var suite *framework.K2sTestSuite
var client kubernetes.Interface
var configDir string

func TestNodeRename(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Linux Worker Rename Acceptance Tests",
		Label("cli", "acceptance", "setup-required", "system-running", "node-rename", "disruptive", "internet-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	if runtime.GOOS != "windows" {
		Skip("Worker rename is supported only from the Windows K2s host")
	}
	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepTimeout(20*time.Minute),
		framework.ClusterTestStepPollInterval(500*time.Millisecond))
	DeferCleanup(suite.TearDown)
	configDir = suite.SetupInfo().Config.Host().K2sSetupConfigDir()
	config, err := clusterconfig.Read(configDir)
	Expect(err).NotTo(HaveOccurred())
	if config == nil || !slices.ContainsFunc(config.Nodes, func(node clusterconfig.Node) bool { return node.Role == clusterconfig.RoleWorker }) {
		Skip("Skipping node rename tests: no worker nodes found in cluster.json")
	}
	client, err = kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
	Expect(err).NotTo(HaveOccurred())
})

var _ = Describe("node rename rejections", Serial, func() {
	It("rejects missing names, equal names, a missing old Node, and the control plane", func(ctx SpecContext) {
		nodes, err := client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
		Expect(err).NotTo(HaveOccurred())
		descriptor := readDescriptor()
		for _, args := range [][]string{
			{},
			{"--old-name", "old-node"},
			{"--new-name", "new-node"},
			{"--old-name", "same-node", "--new-name", "SAME-NODE"},
		} {
			rejectRename(ctx, args...)
		}
		missing := uniqueName()
		output := rejectRename(ctx, "--old-name", missing, "--new-name", missing+"-new")
		Expect(output).To(ContainSubstring("does not exist"))

		controlPlanes := 0
		for _, node := range nodes.Items {
			if _, found := node.Labels["node-role.kubernetes.io/control-plane"]; found {
				output = rejectRename(ctx, "--old-name", node.Name, "--new-name", uniqueName())
				Expect(output).To(ContainSubstring("control-plane"))
				controlPlanes++
			}
		}
		Expect(controlPlanes).To(BeNumerically(">", 0))
		Expect(readDescriptor()).To(Equal(descriptor))
		for _, before := range nodes.Items {
			after := getNode(ctx, before.Name)
			Expect(after.UID).To(Equal(before.UID))
			Expect(after.Spec.Unschedulable).To(Equal(before.Spec.Unschedulable))
		}
	})

	It("rejects an unmanaged Linux Node and an unsupported managed Node type", func(ctx SpecContext) {
		name := uniqueName()
		node, err := client.CoreV1().Nodes().Create(ctx, &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: name, Labels: map[string]string{"kubernetes.io/os": "linux"}},
			Spec:       corev1.NodeSpec{Unschedulable: true},
		}, metav1.CreateOptions{})
		Expect(err).NotTo(HaveOccurred())
		DeferCleanup(func(ctx SpecContext) {
			err := client.CoreV1().Nodes().Delete(ctx, name, metav1.DeleteOptions{Preconditions: &metav1.Preconditions{UID: &node.UID}})
			Expect(err == nil || apierrors.IsNotFound(err)).To(BeTrue(), "delete synthetic Node: %v", err)
			Eventually(func() error {
				_, err := client.CoreV1().Nodes().Get(ctx, name, metav1.GetOptions{})
				if !apierrors.IsNotFound(err) {
					return fmt.Errorf("waiting for synthetic Node %s deletion: %v", name, err)
				}
				pods, err := client.CoreV1().Pods("").List(ctx, metav1.ListOptions{})
				if err != nil {
					return err
				}
				pending := 0
				for _, pod := range pods.Items {
					if !daemonPodTargetsNode(&pod, name) {
						continue
					}
					pending++
					if pod.DeletionTimestamp != nil {
						continue
					}
					GinkgoWriter.Printf("Removing DaemonSet Pod %s/%s targeting deleted synthetic Node %s\n", pod.Namespace, pod.Name, name)
					err := client.CoreV1().Pods(pod.Namespace).Delete(ctx, pod.Name, metav1.DeleteOptions{
						Preconditions: &metav1.Preconditions{UID: &pod.UID},
					})
					if err != nil && !apierrors.IsNotFound(err) {
						return err
					}
				}
				if pending != 0 {
					return fmt.Errorf("waiting for %d DaemonSet Pods targeting synthetic Node %s to disappear", pending, name)
				}
				return nil
			}, 2*time.Minute, 2*time.Second).Should(Succeed())
		}, NodeTimeout(3*time.Minute))
		output := rejectRename(ctx, "--old-name", name, "--new-name", name+"-new")
		Expect(output).To(ContainSubstring("not managed by K2s"))

		original := readDescriptor()
		modified, err := appendUnsupportedWorker(original, name)
		Expect(err).NotTo(HaveOccurred())
		path := clusterconfig.ConfigPath(configDir)
		DeferCleanup(func() {
			// Do not overwrite another process's cluster.json changes.
			Expect(readDescriptor()).To(Equal(modified), "cluster.json changed concurrently; restore the synthetic entry manually")
			Expect(os.WriteFile(path, original, 0o600)).To(Succeed())
		})
		Expect(os.WriteFile(path, modified, 0o600)).To(Succeed())
		output = rejectRename(ctx, "--old-name", name, "--new-name", name+"-new")
		Expect(output).To(ContainSubstring("Unsupported node type"))
		Expect(getNode(ctx, name).UID).To(Equal(node.UID))
		Expect(readDescriptor()).To(Equal(modified))
	})
})

var _ = Describe("managed Linux worker rename", Serial, func() {
	It("preserves identity and SMB data while rejecting partial workloads and recovering with --force", func(ctx SpecContext) {
		config, err := clusterconfig.Read(configDir)
		Expect(err).NotTo(HaveOccurred())
		worker, err := renameWorker(config)
		Expect(err).NotTo(HaveOccurred())
		Expect(getNode(ctx, worker.Name).Spec.Unschedulable).To(BeFalse(),
			"the fixture worker must be schedulable before this test: SMB access must be verified from a newly scheduled Pod on the renamed Node, not only kubemaster")
		_, err = client.CoreV1().Nodes().Get(ctx, newNodeName, metav1.GetOptions{})
		Expect(apierrors.IsNotFound(err)).To(BeTrue(), "replacement name must not already exist")
		By(fmt.Sprintf("renaming %s worker %s to %s at %s using stored SSH user %s", worker.NodeType, worker.Name, newNodeName, worker.IpAddress, worker.Username))
		exerciseRename(ctx, worker, ensureLinuxSMB(ctx))
	})
})

func exerciseRename(ctx SpecContext, worker clusterconfig.Node, storageClass string) {
	original := getNode(ctx, worker.Name).DeepCopy()
	Expect(isReady(original)).To(BeTrue())
	Expect(original.Spec.PodCIDR).NotTo(BeEmpty())
	Expect(original.Spec.PodCIDR).To(Equal(worker.PodCIDR))
	originalHostname := remote(ctx, worker, "hostname")
	Expect(strings.EqualFold(originalHostname, worker.Name)).To(BeTrue(), "the worker must not already have a different OS hostname")
	Expect(original.Labels).NotTo(HaveKey(metadataKey))
	Expect(original.Annotations).NotTo(HaveKey(metadataKey))
	for _, taint := range original.Spec.Taints {
		Expect(taint.Key).NotTo(Equal(metadataKey))
	}
	newName := newNodeName
	_, err := client.CoreV1().Nodes().Get(ctx, newName, metav1.GetOptions{})
	Expect(apierrors.IsNotFound(err)).To(BeTrue(), "replacement name must not already exist")
	descriptor := readDescriptor()
	unrelated, err := client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	Expect(err).NotTo(HaveOccurred())
	hostnameChanged := false
	renamed := false
	cleaned := false

	cleanupWorker := func(ctx SpecContext) {
		if cleaned {
			return
		}
		for _, name := range []string{worker.Name, newName} {
			_, err := client.CoreV1().Nodes().Get(ctx, name, metav1.GetOptions{})
			if apierrors.IsNotFound(err) {
				continue
			}
			Expect(err).NotTo(HaveOccurred(), "inspect Node during test metadata cleanup")
			mutateNode(ctx, name, func(node *corev1.Node) {
				delete(node.Labels, metadataKey)
				delete(node.Annotations, metadataKey)
				node.Spec.Taints = slices.DeleteFunc(node.Spec.Taints, func(taint corev1.Taint) bool { return taint.Key == metadataKey })
				if (renamed && name == newName) || (!hostnameChanged && name == worker.Name) {
					node.Spec.Unschedulable = original.Spec.Unschedulable
				}
			})
		}
		if hostnameChanged && !renamed {
			GinkgoWriter.Printf("Rename did not complete; inspect Nodes %q and %q and worker %s. Hostname and rename recovery markers are left unchanged; no automatic recovery rename was attempted.\n", worker.Name, newName, worker.IpAddress)
		}
		cleaned = true
	}
	DeferCleanup(cleanupWorker, NodeTimeout(4*time.Minute))

	By("rejecting a hostname mismatch without changing services, Nodes or cluster.json")
	serviceState := readKubeletIdentity(ctx, worker)
	output := rejectRename(ctx, "--old-name", worker.Name, "--new-name", newName)
	Expect(output).To(ContainSubstring("does not match"))
	Expect(output).To(ContainSubstring("No changes were made"))
	unchanged := getNode(ctx, worker.Name)
	Expect(unchanged.UID).To(Equal(original.UID))
	Expect(unchanged.Spec).To(Equal(original.Spec))
	Expect(unchanged.Labels).To(Equal(original.Labels))
	Expect(unchanged.Annotations).To(Equal(original.Annotations))
	Expect(readDescriptor()).To(Equal(descriptor))
	Expect(readKubeletIdentity(ctx, worker)).To(Equal(serviceState))

	mutateNode(ctx, worker.Name, func(node *corev1.Node) {
		if node.Labels == nil {
			node.Labels = map[string]string{}
		}
		if node.Annotations == nil {
			node.Annotations = map[string]string{}
		}
		node.Labels[metadataKey] = newName
		node.Annotations[metadataKey] = newName
		node.Spec.Taints = append(node.Spec.Taints, corev1.Taint{Key: metadataKey, Value: newName, Effect: corev1.TaintEffectNoSchedule})
		node.Spec.Unschedulable = false
	})
	migration := createMigrationWorkload(ctx, worker, newName, storageClass)
	mutateNode(ctx, worker.Name, func(node *corev1.Node) {
		node.Spec.Unschedulable = original.Spec.Unschedulable
	})
	saved := getNode(ctx, worker.Name).DeepCopy()
	hostnameChanged = true
	setHostname(ctx, worker, newName)
	rebootWorker(ctx, worker, newName)

	var partial *corev1.Node
	partial, err = client.CoreV1().Nodes().Get(ctx, newName, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		partial = nil
	} else {
		Expect(err).NotTo(HaveOccurred())
	}
	if partial == nil {
		By("creating a partial registration when the reboot did not automatically register one")
		partial, err = client.CoreV1().Nodes().Create(ctx, &corev1.Node{
			ObjectMeta: metav1.ObjectMeta{Name: newName, Labels: map[string]string{"kubernetes.io/os": "linux"}},
			Spec:       corev1.NodeSpec{Unschedulable: true},
		}, metav1.CreateOptions{})
		if apierrors.IsAlreadyExists(err) {
			partial = getNode(ctx, newName)
		} else {
			Expect(err).NotTo(HaveOccurred())
			Expect(retry.RetryOnConflict(retry.DefaultRetry, func() error {
				current, err := client.CoreV1().Nodes().Get(ctx, newName, metav1.GetOptions{})
				if err != nil {
					return err
				}
				current.Status.Addresses = []corev1.NodeAddress{{Type: corev1.NodeInternalIP, Address: worker.IpAddress}}
				current.Status.Conditions = []corev1.NodeCondition{{Type: corev1.NodeReady, Status: corev1.ConditionFalse}}
				_, err = client.CoreV1().Nodes().UpdateStatus(ctx, current, metav1.UpdateOptions{})
				return err
			})).To(Succeed())
		}
	}
	Expect(partial).NotTo(BeNil())
	By("cordoning the partial registration before testing its recovery")
	mutateNode(ctx, newName, func(node *corev1.Node) { node.Spec.Unschedulable = true })
	Eventually(func() (bool, error) {
		current, err := client.CoreV1().Nodes().Get(ctx, newName, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		return slices.ContainsFunc(current.Status.Addresses, func(address corev1.NodeAddress) bool {
			return address.Type == corev1.NodeInternalIP && address.Address == worker.IpAddress
		}), nil
	}, time.Minute, time.Second).Should(BeTrue(), "the partial registration must belong to the same worker IP")
	namespace := newName + "-recovery"
	_, err = client.CoreV1().Namespaces().Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: namespace}}, metav1.CreateOptions{})
	Expect(err).NotTo(HaveOccurred())
	removed := false
	removeWorkload := func(ctx SpecContext) {
		if removed {
			return
		}
		err := client.CoreV1().Namespaces().Delete(ctx, namespace, metav1.DeleteOptions{})
		Expect(err == nil || apierrors.IsNotFound(err)).To(BeTrue(), "delete test namespace: %v", err)
		Eventually(func() bool {
			_, err := client.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
			return apierrors.IsNotFound(err)
		}, 3*time.Minute, time.Second).Should(BeTrue(), "remove the synthetic partial-registration workload")
		removed = true
	}
	DeferCleanup(removeWorkload, NodeTimeout(4*time.Minute))
	_, err = client.CoreV1().Pods(namespace).Create(ctx, &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "partial-workload"},
		Spec: corev1.PodSpec{
			NodeName: newName,
			Containers: []corev1.Container{{
				Name: "never-pull", Image: "k2s-node-rename-test.invalid/never-pull:local", ImagePullPolicy: corev1.PullNever,
			}},
			Tolerations: []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
		},
	}, metav1.CreateOptions{})
	Expect(err).NotTo(HaveOccurred())
	By("refusing a partial replacement carrying user workloads without deleting either Node")
	beforeRejection := readKubeletIdentity(ctx, worker)
	output = rejectRename(ctx, "--old-name", worker.Name, "--new-name", newName)
	Expect(output).To(ContainSubstring("--force"))
	Expect(output).To(ContainSubstring("partial-workload"))
	Expect(getNode(ctx, worker.Name).UID).To(Equal(original.UID))
	Expect(getNode(ctx, newName).UID).To(Equal(partial.UID))
	Expect(readDescriptor()).To(Equal(descriptor))
	Expect(readKubeletIdentity(ctx, worker)).To(Equal(beforeRejection))

	observer := observeRename(ctx)
	// Uppercase input exercises case-insensitive hostname validation and lowercase normalization.
	output = rename(ctx, worker.Name, strings.ToUpper(newName))
	renamed = true
	replacement := getNode(ctx, newName)
	Expect(isReady(replacement)).To(BeTrue())
	Expect(replacement.UID).NotTo(Equal(original.UID))
	Expect(replacement.UID).NotTo(Equal(partial.UID), "recreate, rather than reuse, an unowned partial registration")
	Expect(replacement.Spec.PodCIDR).To(Equal(saved.Spec.PodCIDR))
	Expect(replacement.Spec.PodCIDRs).To(Equal(saved.Spec.PodCIDRs))
	Expect(replacement.Spec.Unschedulable).To(Equal(original.Spec.Unschedulable))
	Expect(replacement.Labels["kubernetes.io/os"]).To(Equal("linux"))
	Expect(replacement.Labels["kubernetes.io/hostname"]).To(Equal(newName))
	for key, value := range saved.Labels {
		if !managedKey(key) {
			Expect(replacement.Labels).To(HaveKeyWithValue(key, value))
		}
	}
	for key, value := range saved.Annotations {
		if !managedKey(key) && !strings.HasPrefix(key, "flannel.alpha.coreos.com/") && !strings.HasPrefix(key, "k2s.io/rename-") {
			Expect(replacement.Annotations).To(HaveKeyWithValue(key, value))
		}
	}
	for _, taint := range saved.Spec.Taints {
		if !managedKey(taint.Key) {
			Expect(replacement.Spec.Taints).To(ContainElement(taint))
		}
	}
	for key := range replacement.Annotations {
		Expect(key).NotTo(HavePrefix("k2s.io/rename-"))
	}
	_, err = client.CoreV1().Nodes().Get(ctx, worker.Name, metav1.GetOptions{})
	Expect(apierrors.IsNotFound(err)).To(BeTrue())
	readyLog := strings.Index(output, fmt.Sprintf("Node '%s' is Ready and its kubelet certificate", newName))
	deleteLog := strings.Index(output, fmt.Sprintf("Deleting old Node '%s'", worker.Name))
	Expect(readyLog).To(BeNumerically(">=", 0))
	Expect(deleteLog).To(BeNumerically(">", readyLog), "validate replacement before retiring old identity")
	cordonLog := strings.Index(output, fmt.Sprintf("Cordoning old Node '%s'", worker.Name))
	drainLog := strings.Index(output, fmt.Sprintf("Draining old Node '%s'", worker.Name))
	Expect(cordonLog).To(BeNumerically(">=", 0))
	Expect(drainLog).To(BeNumerically(">", cordonLog))
	Expect(readyLog).To(BeNumerically(">", drainLog))
	By("verifying Node API events show cordon, completed drain, replacement readiness and old identity retirement in order")
	Eventually(func() error { return observer.validate(original.UID, replacement.UID) }, 30*time.Second, 200*time.Millisecond).Should(Succeed())
	observer.stop()
	expectedDescriptor, err := renamedDescriptor(descriptor, worker.Name, newName)
	Expect(err).NotTo(HaveOccurred())
	Expect(bytes.TrimPrefix(readDescriptor(), []byte{0xef, 0xbb, 0xbf})).To(MatchJSON(expectedDescriptor))
	subject := remote(ctx, worker, "sudo -n openssl verify -CAfile /etc/kubernetes/pki/ca.crt /var/lib/kubelet/pki/kubelet-client-current.pem && sudo -n openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -nameopt RFC2253")
	Expect(subject).To(ContainSubstring("CN=system:node:" + newName))
	Expect(subject).To(ContainSubstring("O=system:nodes"))
	Expect(strings.Split(remote(ctx, worker, "sudo -n systemctl is-active kubelet"), "\n")).To(ContainElement("active"))
	migration.verifyAfterRename(ctx, worker.Name, newName)
	for _, before := range unrelated.Items {
		if before.Name == worker.Name {
			continue
		}
		after := getNode(ctx, before.Name)
		Expect(after.UID).To(Equal(before.UID), "unrelated Node %s must not be recreated", before.Name)
		Expect(after.Spec.PodCIDR).To(Equal(before.Spec.PodCIDR))
		Expect(after.Spec.Unschedulable).To(Equal(before.Spec.Unschedulable))
		Expect(isReady(after)).To(BeTrue(), "unrelated Node %s must remain Ready", before.Name)
	}
	removeWorkload(ctx)
	verifyRenamedClusterRestart(ctx, worker.Name)
	Expect(bytes.TrimPrefix(readDescriptor(), []byte{0xef, 0xbb, 0xbf})).To(MatchJSON(expectedDescriptor),
		"stop/start must retain the renamed worker in cluster.json")
	Expect(remote(ctx, worker, "hostname")).To(Equal(newName))
	By("rechecking the original SMB PVC from the renamed worker after k2s stop/start")
	migration.verifyAfterRename(ctx, worker.Name, newName)
	migration.cleanup(ctx)
	cleanupWorker(ctx)
	By(fmt.Sprintf("leaving worker %s renamed to %s in the OS, Kubernetes and cluster.json", worker.IpAddress, newName))
}

func rename(ctx context.Context, oldName, newName string) string {
	args := []string{"node", "rename", "--old-name", oldName, "--new-name", newName, "--timeout", "15m", "-o", "--force"}
	output := suite.K2sCli().MustExec(ctx, args...)
	Expect(output).To(ContainSubstring("SUCCESS"))
	return output
}

func rejectRename(ctx context.Context, args ...string) string {
	output, code := suite.K2sCli().Exec(ctx, append([]string{"node", "rename"}, args...)...)
	Expect(code).NotTo(BeZero(), "a rejected rename must have a failing process exit code")
	Expect(output).NotTo(ContainSubstring("SUCCESS"))
	return output
}

func remote(ctx context.Context, worker clusterconfig.Node, command string) string {
	return strings.TrimSpace(suite.K2sCli().MustExec(ctx, "node", "exec",
		"--ip-addr", worker.IpAddress, "--username", worker.Username, "--command", command, "--raw"))
}

func setHostname(ctx context.Context, worker clusterconfig.Node, name string) {
	remote(ctx, worker, "sudo -n hostnamectl set-hostname '"+name+"'")
	Expect(remote(ctx, worker, "hostname")).To(Equal(name))
}

func readKubeletIdentity(ctx context.Context, worker clusterconfig.Node) string {
	return remote(ctx, worker, "sudo -n systemctl show kubelet -p ActiveState -p ExecMainStartTimestampMonotonic && sudo -n sha256sum /var/lib/kubelet/kubeadm-flags.env /var/lib/kubelet/pki/kubelet-client-current.pem")
}

func getNode(ctx context.Context, name string) *corev1.Node {
	node, err := client.CoreV1().Nodes().Get(ctx, name, metav1.GetOptions{})
	Expect(err).NotTo(HaveOccurred())
	return node
}

func mutateNode(ctx context.Context, name string, mutate func(*corev1.Node)) {
	Expect(retry.RetryOnConflict(retry.DefaultRetry, func() error {
		node, err := client.CoreV1().Nodes().Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return err
		}
		mutate(node)
		_, err = client.CoreV1().Nodes().Update(ctx, node, metav1.UpdateOptions{})
		return err
	})).To(Succeed())
}

func readDescriptor() []byte {
	data, err := os.ReadFile(clusterconfig.ConfigPath(configDir))
	Expect(err).NotTo(HaveOccurred())
	return data
}

func renameWorker(config *clusterconfig.Cluster) (clusterconfig.Node, error) {
	var matches []clusterconfig.Node
	if config != nil {
		for _, node := range config.Nodes {
			if node.Name == oldNodeName {
				matches = append(matches, node)
			}
		}
	}
	if len(matches) != 1 {
		return clusterconfig.Node{}, fmt.Errorf("expected exactly one worker named %q in cluster.json, found %d; provision it with k2s node add before running this suite", oldNodeName, len(matches))
	}
	worker := matches[0]
	if worker.OS != clusterconfig.OsTypeLinux || worker.Role != clusterconfig.RoleWorker ||
		(worker.NodeType != clusterconfig.NodeTypeHost && worker.NodeType != clusterconfig.NodeTypeVMExisting) {
		return clusterconfig.Node{}, fmt.Errorf("worker %q must be a managed Linux HOST or VM-EXISTING worker", oldNodeName)
	}
	return worker, nil
}

func uniqueName() string {
	return fmt.Sprintf("k2s-rename-%x", time.Now().UnixNano())
}

func daemonPodTargetsNode(pod *corev1.Pod, nodeName string) bool {
	owner := metav1.GetControllerOf(pod)
	if owner == nil || owner.Kind != "DaemonSet" || owner.APIVersion != "apps/v1" {
		return false
	}
	if pod.Spec.NodeName != "" {
		return pod.Spec.NodeName == nodeName
	}
	affinity := pod.Spec.Affinity
	if affinity == nil || affinity.NodeAffinity == nil || affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution == nil {
		return false
	}
	terms := affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms
	if len(terms) != 1 {
		return false
	}
	return slices.ContainsFunc(terms[0].MatchFields, func(field corev1.NodeSelectorRequirement) bool {
		return field.Key == "metadata.name" && field.Operator == corev1.NodeSelectorOpIn &&
			len(field.Values) == 1 && field.Values[0] == nodeName
	})
}

func isReady(node *corev1.Node) bool {
	return slices.ContainsFunc(node.Status.Conditions, func(condition corev1.NodeCondition) bool {
		return condition.Type == corev1.NodeReady && condition.Status == corev1.ConditionTrue
	})
}

func managedKey(key string) bool {
	domain, _, found := strings.Cut(key, "/")
	return found && (domain == "kubernetes.io" || domain == "k8s.io" || strings.HasSuffix(domain, ".kubernetes.io") || strings.HasSuffix(domain, ".k8s.io"))
}

func appendUnsupportedWorker(data []byte, name string) ([]byte, error) {
	return editDescriptor(data, func(nodes []map[string]json.RawMessage) ([]map[string]json.RawMessage, error) {
		entry, err := json.Marshal(clusterconfig.Node{Name: name, NodeType: "UNSUPPORTED-E2E", OS: "linux", Role: "worker"})
		if err != nil {
			return nil, err
		}
		var node map[string]json.RawMessage
		if err := json.Unmarshal(entry, &node); err != nil {
			return nil, err
		}
		return append(nodes, node), nil
	})
}

func renamedDescriptor(data []byte, oldName, newName string) ([]byte, error) {
	return editDescriptor(data, func(nodes []map[string]json.RawMessage) ([]map[string]json.RawMessage, error) {
		found := 0
		for _, node := range nodes {
			var name string
			if err := json.Unmarshal(node["Name"], &name); err != nil {
				return nil, err
			}
			if name == oldName {
				encodedName, err := json.Marshal(newName)
				if err != nil {
					return nil, err
				}
				node["Name"] = encodedName
				found++
			}
		}
		if found != 1 {
			return nil, fmt.Errorf("expected exactly one cluster.json entry for %q, found %d", oldName, found)
		}
		return nodes, nil
	})
}

func editDescriptor(data []byte, edit func([]map[string]json.RawMessage) ([]map[string]json.RawMessage, error)) ([]byte, error) {
	var descriptor map[string]json.RawMessage
	if err := json.Unmarshal(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf}), &descriptor); err != nil {
		return nil, err
	}
	var nodes []map[string]json.RawMessage
	if err := json.Unmarshal(descriptor["nodes"], &nodes); err != nil {
		return nil, err
	}
	nodes, err := edit(nodes)
	if err != nil {
		return nil, err
	}
	descriptor["nodes"], err = json.Marshal(nodes)
	if err != nil {
		return nil, err
	}
	return json.Marshal(descriptor)
}
