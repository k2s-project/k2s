// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package k8s

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"

	//lint:ignore ST1001 test framework code

	. "github.com/onsi/ginkgo/v2"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/e2e-framework/klient"
	"sigs.k8s.io/e2e-framework/klient/conf"
	k8sklient "sigs.k8s.io/e2e-framework/klient/k8s"
	"sigs.k8s.io/e2e-framework/klient/wait"
	"sigs.k8s.io/e2e-framework/klient/wait/conditions"
	"sigs.k8s.io/e2e-framework/pkg/envconf"
)

type Cluster struct {
	*envconf.Config
	testStepTimeout      time.Duration
	testStepPollInterval time.Duration
}

const clusterReadinessTimeout = 10 * time.Minute

const (
	internetReachabilityCurlMaxTime       = "20"
	internetReachabilityCurlRetryCount    = "0"
	internetReachabilityCheckTimeout      = 15 * time.Minute
	internetReachabilityCheckPollInterval = 15 * time.Second
)

type podExecParam struct {
	Namespace string
	Pod       string
	Container string
	Command   []string
	Config    *rest.Config
	Ctx       context.Context
	Stdout    *bytes.Buffer
	Stderr    *bytes.Buffer
}

func NewCluster(testStepTimeout time.Duration, testStepPollInterval time.Duration) *Cluster {
	configFilePath := conf.ResolveKubeConfigFile()
	kubeConfig := envconf.NewWithKubeConfig(configFilePath)

	return &Cluster{
		Config:               kubeConfig,
		testStepTimeout:      testStepTimeout,
		testStepPollInterval: testStepPollInterval,
	}
}

func (c *Cluster) ExpectDeploymentToBeAvailable(name string, namespace string) {
	dep := appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace},
	}

	condition := conditions.New(c.Client().Resources()).DeploymentConditionMatch(&dep, appsv1.DeploymentAvailable, corev1.ConditionTrue)

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())
}

func (c *Cluster) ExpectDeploymentToBeRemoved(ctx context.Context, labelName string, deploymentName string, namespace string) {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())

	areAllContainersExited := func() (bool, error) {
		pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: fmt.Sprintf("%s=%s", labelName, deploymentName)})
		if err != nil {
			return false, err
		}

		for _, pod := range pods.Items {
			GinkgoWriter.Println("Pod name:", pod.Name, "| Pod Status:", pod.Status.Phase)
			for _, container := range pod.Status.ContainerStatuses {
				GinkgoWriter.Println("Container name:", container.Name, "| Container Status:", container.State)
				// Check if the container has terminated
				if container.State.Terminated == nil {
					GinkgoWriter.Println("Waiting for all containers to exit...")
					return false, nil
				}
			}
		}
		return true, nil
	}

	Eventually(areAllContainersExited, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue())

	IsDeploymentAvailable := func() (bool, error) {
		deploymentsClient := clientSet.AppsV1().Deployments(namespace)

		deploymentList, err := deploymentsClient.List(ctx, metav1.ListOptions{})
		Expect(err).To(BeNil())

		for _, deployment := range deploymentList.Items {
			if deployment.Name == deploymentName {
				return true, nil
			}
		}

		return false, nil
	}

	Eventually(areAllContainersExited, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue())
	Eventually(IsDeploymentAvailable, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeFalse())
}

func (c *Cluster) ExpectDeploymentToBeReachableFromPodOfOtherDeployment(targetName string, targetNamespace string, sourceName string, sourceNamespace string, ctx context.Context) {
	client := c.Client()

	pod, err := determineFirstPodOfDeployment(sourceName, sourceNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	var stdout, stderr bytes.Buffer
	command := []string{"curl", "-i", "-m", "10", "--retry", "3", "http://" + targetName + "." + targetNamespace + ".svc.cluster.local/" + targetName}

	param := podExecParam{
		Namespace: sourceNamespace,
		Pod:       pod.Name,
		Container: sourceName,
		Command:   command,
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	expectCmdExecInPodToSucceed(param)
}

func (c *Cluster) ExpectDeploymentToBeReachableFromPodOfOtherDeploymentAtPort(targetName string, targetNamespace string, sourceName string, sourceNamespace string, port string, ctx context.Context) {
	client := c.Client()

	pod, err := determineFirstPodOfDeployment(sourceName, sourceNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	var stdout, stderr bytes.Buffer
	command := []string{"curl", "-i", "-m", "10", "--retry", "3", "http://" + targetName + "." + targetNamespace + ".svc.cluster.local:" + port + "/" + targetName}

	param := podExecParam{
		Namespace: sourceNamespace,
		Pod:       pod.Name,
		Container: sourceName,
		Command:   command,
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	expectCmdExecInPodToSucceed(param)
}

func (c *Cluster) ExpectDeploymentNotToBeReachableFromPodOfOtherDeployment(targetName string, targetNamespace string, sourceName string, sourceNamespace string, ctx context.Context) {
	client := c.Client()

	pod, err := determineFirstPodOfDeployment(sourceName, sourceNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	var stdout, stderr bytes.Buffer
	command := []string{"curl", "-i", "-m", "10", "--retry", "3", "http://" + targetName + "." + targetNamespace + ".svc.cluster.local/" + targetName}

	param := podExecParam{
		Namespace: sourceNamespace,
		Pod:       pod.Name,
		Container: sourceName,
		Command:   command,
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	expectCmdExecInPodToBeForbidden(param)
}

func (c *Cluster) ExpectStatefulSetToBeReady(name string, namespace string, expectedReplicas int32, ctx context.Context) {
	statefulSet := appsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	resources := c.Client().Resources(namespace)

	condition := conditions.New(resources).ResourceMatch(&statefulSet, func(object k8sklient.Object) bool {
		set := object.(*appsv1.StatefulSet)

		return set.Status.AvailableReplicas == expectedReplicas && set.Status.ReadyReplicas == expectedReplicas
	})

	GinkgoWriter.Println("Waiting for StatefulSet <", name, "> to be ready..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("StatefulSet <", name, "> ready.")

	pods := &corev1.PodList{}

	GinkgoWriter.Println("Retrieving all Pods of namespace <", namespace, ">..")

	Expect(resources.List(ctx, pods)).To(Succeed())

	GinkgoWriter.Println("Found <", len(pods.Items), "> Pod(s).")

	for _, pod := range pods.Items {
		if len(pod.OwnerReferences) > 0 && pod.OwnerReferences[0].Name == name {
			condition := conditions.New(resources).PodReady(&pod)

			GinkgoWriter.Println("Waiting for Pod <", pod.Name, "> of StatefulSet <", name, "> to be ready..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Pod ready")

			condition = conditions.New(resources).ContainersReady(&pod)

			GinkgoWriter.Println("Waiting for containers of Pod <", pod.Name, "> of StatefulSet <", name, "> to be ready..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Containers ready")
		}
	}
}

func (c *Cluster) ExpectPersistentVolumeToBeBound(name string, namespace string, expectedPVClaims int32, ctx context.Context) {
	var pvcList corev1.PersistentVolumeClaimList
	err := c.Client().Resources(namespace).List(ctx, &pvcList)
	Expect(err).ToNot(HaveOccurred(), "failed to list PVCs in namespace %s", namespace)

	Expect(len(pvcList.Items)).To(Equal(int(expectedPVClaims)), "expected exactly %d PVC in namespace %s, found %d", expectedPVClaims, namespace, len(pvcList.Items))

	pvc := pvcList.Items[0]
	Expect(pvc.Name).To(Equal(name), "the only PVC in namespace %s should be %s", namespace, name)

	condition := conditions.New(c.Client().Resources(namespace)).ResourceMatch(&pvc, func(object k8sklient.Object) bool {
		foundPVC := object.(*corev1.PersistentVolumeClaim)
		return foundPVC.Status.Phase == corev1.ClaimBound
	})

	GinkgoWriter.Println("Waiting for PersistentVolumeClaim <", name, "> to be bound..")
	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())
}

func (c *Cluster) ExpectStatefulSetToBeDeleted(name string, namespace string, ctx context.Context) {
	statefulSet := appsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	resources := c.Client().Resources(namespace)

	condition := conditions.New(resources).ResourceDeleted(&statefulSet)

	GinkgoWriter.Println("Waiting for StatefulSet <", name, "> to be deleted..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("StatefulSet <", name, "> deleted.")

	pods := &corev1.PodList{}

	GinkgoWriter.Println("Retrieving all Pods of namespace <", namespace, ">..")

	Expect(resources.List(ctx, pods)).To(Succeed())

	GinkgoWriter.Println("Found <", len(pods.Items), "> Pod(s).")

	for _, pod := range pods.Items {
		if len(pod.OwnerReferences) > 0 && pod.OwnerReferences[0].Name == name {
			condition := conditions.New(resources).ResourceDeleted(&pod)

			GinkgoWriter.Println("Waiting for Pod <", pod.Name, "> of StatefulSet <", name, "> to be deleted..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Pod deleted")
		}
	}
}

func (c *Cluster) ExpectDaemonSetToBeReady(name string, namespace string, expectedNumber int32, ctx context.Context) {
	daemonSet := appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	resources := c.Client().Resources(namespace)

	condition := conditions.New(resources).ResourceMatch(&daemonSet, func(object k8sklient.Object) bool {
		set := object.(*appsv1.DaemonSet)

		return set.Status.NumberAvailable == expectedNumber && set.Status.NumberReady == expectedNumber
	})

	GinkgoWriter.Println("Waiting for DaemonSet <", name, "> to be ready..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("DaemonSet <", name, "> ready.")

	pods := &corev1.PodList{}

	GinkgoWriter.Println("Retrieving all Pods of namespace <", namespace, ">..")

	Expect(resources.List(ctx, pods)).To(Succeed())

	GinkgoWriter.Println("Found <", len(pods.Items), "> Pod(s).")

	for _, pod := range pods.Items {
		if len(pod.OwnerReferences) > 0 && pod.OwnerReferences[0].Name == name {
			condition := conditions.New(resources).PodReady(&pod)

			GinkgoWriter.Println("Waiting for Pod <", pod.Name, "> of DaemonSet <", name, "> to be ready..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Pod ready")

			condition = conditions.New(resources).ContainersReady(&pod)

			GinkgoWriter.Println("Waiting for containers of Pod <", pod.Name, "> of DaemonSet <", name, "> to be ready..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Containers ready")
		}
	}
}

func (c *Cluster) ExpectDaemonSetToBeDeleted(name string, namespace string, ctx context.Context) {
	daemonSet := appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	resources := c.Client().Resources(namespace)

	condition := conditions.New(resources).ResourceDeleted(&daemonSet)

	GinkgoWriter.Println("Waiting for DaemonSet <", name, "> to be deleted..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("DaemonSet <", name, "> deleted.")

	pods := &corev1.PodList{}

	GinkgoWriter.Println("Retrieving all Pods of namespace <", namespace, ">..")

	Expect(resources.List(ctx, pods)).To(Succeed())

	GinkgoWriter.Println("Found <", len(pods.Items), "> Pod(s).")

	for _, pod := range pods.Items {
		if len(pod.OwnerReferences) > 0 && pod.OwnerReferences[0].Name == name {
			condition := conditions.New(resources).ResourceDeleted(&pod)

			GinkgoWriter.Println("Waiting for Pod <", pod.Name, "> of DaemonSet <", name, "> to be deleted..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Pod deleted")
		}
	}
}

func (c *Cluster) ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment(targetName string, targetNamespace string, sourceName string, sourceNamespace string, ctx context.Context) {
	client := c.Client()

	sourcePod, err := determineFirstPodOfDeployment(sourceName, sourceNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	targetPod, err := determineFirstPodOfDeployment(targetName, targetNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	var stdout, stderr bytes.Buffer

	param := podExecParam{
		Namespace: sourceNamespace,
		Pod:       sourcePod.Name,
		Container: sourceName,
		Command:   []string{"curl", "-i", "-m", "10", "--retry", "3", "http://" + targetPod.Status.PodIP + "/" + targetName},
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	expectCmdExecInPodToSucceed(param)
}

// This is used when cluster restart is performed to ensure all system pods are up and running
func (c *Cluster) ExpectClusterIsRunningAfterRestart(ctx context.Context) {
	// Run the check 5 times with a 5-second interval to ensure cluster has started
	for i := 0; i < 5; i++ {
		GinkgoWriter.Println("************************Iteration:", i+1, "************************")
		if c.AreAllPodsReady(ctx, "kube-system") {
			GinkgoWriter.Println("Iteration:", i+1, "kube-system pods are ready")
		} else {
			GinkgoWriter.Println("Iteration:", i+1, "kube-system pods are not ready")
		}

		if c.AreAllPodsReady(ctx, "kube-flannel") {
			GinkgoWriter.Println("Iteration:", i+1, "kube-flannel pods are ready")
		} else {
			GinkgoWriter.Println("Iteration:", i+1, "kube-flannel pods are not ready")
		}

		// Wait for 5 seconds before the next check
		time.Sleep(5 * time.Second)
	}
	Expect(c.AreAllPodsReady(ctx, "kube-system")).To(BeTrue())
	Expect(c.AreAllPodsReady(ctx, "kube-flannel")).To(BeTrue())
}

// This is used to check system pods are up and running, use EnsureClusterIsRunningAfterRestart if the check is needed after restart
func (c *Cluster) ExpectClusterIsRunning(ctx context.Context) {
	c.expectNamespacePodsReady(ctx, "kube-system")
	c.expectNamespacePodsReady(ctx, "kube-flannel")
}

func (c *Cluster) AreAllPodsReady(ctx context.Context, namespace string) bool {
	return c.areAllPodsReady(ctx, namespace, true)
}

func (c *Cluster) expectNamespacePodsReady(ctx context.Context, namespace string) {
	timeout := c.testStepTimeout
	if timeout < clusterReadinessTimeout {
		timeout = clusterReadinessTimeout
	}

	deadline := time.Now().Add(timeout)

	for {
		if c.areAllPodsReady(ctx, namespace, false) {
			return
		}

		if time.Now().After(deadline) {
			c.writeNamespaceReadinessDiagnostics(ctx, namespace)
			Expect(false).To(BeTrue(), "Not all pods are ready in namespace: %s after %s", namespace, timeout)
			return
		}

		select {
		case <-ctx.Done():
			c.writeNamespaceReadinessDiagnostics(context.Background(), namespace)
			Expect(ctx.Err()).ToNot(HaveOccurred(), "context ended while waiting for pods in namespace: %s", namespace)
			return
		case <-time.After(c.testStepPollInterval):
		}
	}
}

func (c *Cluster) areAllPodsReady(ctx context.Context, namespace string, verbose bool) bool {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())
	pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		GinkgoT().Logf("Error listing pods in %s namespace: %v", namespace, err)
		return false
	}

	for _, pod := range pods.Items {
		if verbose {
			GinkgoWriter.Println(fmt.Sprintf("Pod: %-40s Status: %-40s", pod.Name, pod.Status.Phase))
		}

		// Check if the pod is in the "Running" phase
		if pod.Status.Phase != "Running" {
			if verbose {
				GinkgoWriter.Println(fmt.Sprintf("Pod: %-40s is not Running yet", pod.Name))
			}
			return false
		}

		for _, condition := range pod.Status.Conditions {
			if condition.Type == corev1.PodReady && condition.Status != corev1.ConditionTrue {
				if verbose {
					GinkgoWriter.Println(fmt.Sprintf("Pod: %-40s is not ready yet Condition Type: %s Condition Status: %s Last Transition Time: %s", pod.Name, condition.Type, condition.Status, condition.LastTransitionTime))
				}
				return false
			}

			if condition.Type == corev1.ContainersReady && condition.Status != corev1.ConditionTrue {
				if verbose {
					GinkgoWriter.Println(fmt.Sprintf("Pod: %-40s containers are not ready yet Condition Type: %s Condition Status: %s Last Transition Time: %s", pod.Name, condition.Type, condition.Status, condition.LastTransitionTime))
				}
				return false
			}
		}

		// Check if all containers in the pod are ready
		for _, containerStatus := range pod.Status.ContainerStatuses {
			if !containerStatus.Ready {
				if verbose {
					GinkgoWriter.Println(fmt.Sprintf("Pod Container: %-40s is not Running yet", pod.Name))
				}
				return false
			}
		}
	}

	return true
}

func (c *Cluster) writeNamespaceReadinessDiagnostics(ctx context.Context, namespace string) {
	clientSet, err := kubernetes.NewForConfig(c.Client().Resources().GetConfig())
	if err != nil {
		GinkgoWriter.Printf("Failed to create Kubernetes client for readiness diagnostics: %v\n", err)
		return
	}

	pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		GinkgoWriter.Printf("Failed to list pods in namespace %s for readiness diagnostics: %v\n", namespace, err)
		return
	}

	GinkgoWriter.Printf("Readiness diagnostics for namespace <%s> (%d pods):\n", namespace, len(pods.Items))

	for _, pod := range pods.Items {
		GinkgoWriter.Printf("Pod %s/%s phase=%s node=%s podIP=%s hostIP=%s startTime=%s\n", pod.Namespace, pod.Name, pod.Status.Phase, pod.Spec.NodeName, pod.Status.PodIP, pod.Status.HostIP, pod.Status.StartTime)

		for _, condition := range pod.Status.Conditions {
			GinkgoWriter.Printf("  Condition type=%s status=%s reason=%q message=%q lastTransition=%s\n", condition.Type, condition.Status, condition.Reason, condition.Message, condition.LastTransitionTime)
		}

		for _, containerStatus := range pod.Status.ContainerStatuses {
			GinkgoWriter.Printf("  Container name=%s ready=%t restartCount=%d state=%s lastState=%s\n", containerStatus.Name, containerStatus.Ready, containerStatus.RestartCount, formatContainerState(containerStatus.State), formatContainerState(containerStatus.LastTerminationState))
		}

		if !isPodReady(pod) {
			c.writePodEvents(ctx, clientSet, pod)
			c.writePodLogs(ctx, clientSet, pod)
		}
	}
}

func isPodReady(pod corev1.Pod) bool {
	if pod.Status.Phase != corev1.PodRunning {
		return false
	}

	for _, condition := range pod.Status.Conditions {
		if condition.Type == corev1.PodReady && condition.Status != corev1.ConditionTrue {
			return false
		}

		if condition.Type == corev1.ContainersReady && condition.Status != corev1.ConditionTrue {
			return false
		}
	}

	for _, containerStatus := range pod.Status.ContainerStatuses {
		if !containerStatus.Ready {
			return false
		}
	}

	return true
}

func (c *Cluster) writePodEvents(ctx context.Context, clientSet *kubernetes.Clientset, pod corev1.Pod) {
	events, err := clientSet.CoreV1().Events(pod.Namespace).List(ctx, metav1.ListOptions{FieldSelector: "involvedObject.name=" + pod.Name})
	if err != nil {
		GinkgoWriter.Printf("  Failed to retrieve events for pod %s/%s: %v\n", pod.Namespace, pod.Name, err)
		return
	}

	if len(events.Items) == 0 {
		GinkgoWriter.Printf("  No events found for pod %s/%s\n", pod.Namespace, pod.Name)
		return
	}

	GinkgoWriter.Printf("  Events for pod %s/%s:\n", pod.Namespace, pod.Name)
	for _, event := range events.Items {
		GinkgoWriter.Printf("    type=%s reason=%s count=%d lastTimestamp=%s message=%q\n", event.Type, event.Reason, event.Count, event.LastTimestamp, event.Message)
	}
}

func (c *Cluster) writePodLogs(ctx context.Context, clientSet *kubernetes.Clientset, pod corev1.Pod) {
	const tailLines int64 = 100

	for _, containerStatus := range pod.Status.ContainerStatuses {
		c.writeContainerLogs(ctx, clientSet, pod, containerStatus.Name, tailLines, false)

		if containerStatus.RestartCount > 0 {
			c.writeContainerLogs(ctx, clientSet, pod, containerStatus.Name, tailLines, true)
		}
	}
}

func (c *Cluster) writeContainerLogs(ctx context.Context, clientSet *kubernetes.Clientset, pod corev1.Pod, containerName string, tailLines int64, previous bool) {
	logs, err := clientSet.CoreV1().Pods(pod.Namespace).GetLogs(pod.Name, &corev1.PodLogOptions{Container: containerName, TailLines: ptrTo(tailLines), Previous: previous}).Do(ctx).Raw()
	logType := "current"
	if previous {
		logType = "previous"
	}

	if err != nil {
		GinkgoWriter.Printf("  Failed to retrieve %s logs for pod %s/%s container %s: %v\n", logType, pod.Namespace, pod.Name, containerName, err)
		return
	}

	GinkgoWriter.Printf("  Last %d %s log lines for not-ready pod %s/%s container %s:\n%s\n", tailLines, logType, pod.Namespace, pod.Name, containerName, string(logs))
}

func ptrTo[T any](value T) *T {
	return &value
}

func formatContainerState(state corev1.ContainerState) string {
	if state.Waiting != nil {
		return fmt.Sprintf("Waiting(reason=%q message=%q)", state.Waiting.Reason, state.Waiting.Message)
	}

	if state.Running != nil {
		return fmt.Sprintf("Running(startedAt=%s)", state.Running.StartedAt)
	}

	if state.Terminated != nil {
		return fmt.Sprintf("Terminated(reason=%q exitCode=%d message=%q finishedAt=%s)", state.Terminated.Reason, state.Terminated.ExitCode, state.Terminated.Message, state.Terminated.FinishedAt)
	}

	return "Unknown"
}

func (c *Cluster) ExpectPodToBeReady(name string, namespace string, hostname string) {
	nameToUse := strings.Replace(name, "HOSTNAME_PLACEHOLDER", hostname, -1)
	namespaceToUse := strings.Replace(namespace, "HOSTNAME_PLACEHOLDER", hostname, -1)

	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: nameToUse, Namespace: namespaceToUse}}

	condition := conditions.New(c.Client().Resources()).PodReady(pod)

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())
}

func (c *Cluster) ExpectPodToBeCompleted(name string, namespace string) {
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	condition := conditions.New(c.Client().Resources(namespace)).ResourceMatch(pod, func(object k8sklient.Object) bool {
		foundPod := object.(*corev1.Pod)

		statuses := foundPod.Status.ContainerStatuses
		if len(statuses) != 1 {
			return false
		}

		terminated := statuses[0].State.Terminated
		if terminated == nil {
			return false
		}

		return terminated.ExitCode == 0
	})

	GinkgoWriter.Println("Waiting for container in Pod <", name, "> (namespace ", namespace, ">) to exit with exit code zero..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("Pod <", name, "> completed")
}

func (c *Cluster) ExpectPodsUnderDeploymentReady(ctx context.Context, labelName string, deploymentName string, namespace string) {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())

	Eventually(func() bool {
		pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: fmt.Sprintf("%s=%s", labelName, deploymentName)})
		if err != nil {
			return false
		}

		// Check if there is at least one pod in the "Running" state.
		for _, pod := range pods.Items {
			GinkgoWriter.Println("Pod name:", pod.Name, "| Pod Status:", pod.Status.Phase)
			if pod.Status.Phase == corev1.PodRunning || pod.Status.Phase == corev1.PodSucceeded {
				GinkgoWriter.Println("At least one pod is running in the deployment:", deploymentName)
				return true
			}
		}

		GinkgoWriter.Println("Waiting for a pod with label name:", labelName, "label value:",
			deploymentName, "namespace", namespace, "to become ready...")
		return false
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue())
}

// getDeploymentSpec fetches the current Deployment and returns its pod template spec.
// Returns (spec, true) on success or (zero, false) when the deployment cannot be read,
// so callers can retry inside an Eventually block during a rollout.
func (c *Cluster) getDeploymentSpec(ctx context.Context, name string, namespace string) (corev1.PodSpec, bool) {
	clientSet, err := kubernetes.NewForConfig(c.Client().Resources().GetConfig())
	if err != nil {
		return corev1.PodSpec{}, false
	}
	dep, err := clientSet.AppsV1().Deployments(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		GinkgoWriter.Println("Could not read deployment <", name, "> in namespace <", namespace, ">:", err)
		return corev1.PodSpec{}, false
	}
	return dep.Spec.Template.Spec, true
}

// ExpectDeploymentInitContainer waits until the deployment's pod template contains an
// init-container with the given name. When expectedImage is non-empty, the init-container's
// image must contain that substring (tolerant of registry/tag/digest variations).
// Generic and reusable across addons — no plugin-specific logic.
func (c *Cluster) ExpectDeploymentInitContainer(ctx context.Context, name string, namespace string, initContainerName string, expectedImage string) {
	GinkgoWriter.Println("Waiting for init-container <", initContainerName, "> on deployment <", name, "> (namespace <", namespace, ">)..")

	Eventually(func() bool {
		spec, ok := c.getDeploymentSpec(ctx, name, namespace)
		if !ok {
			return false
		}
		for _, ic := range spec.InitContainers {
			if ic.Name != initContainerName {
				continue
			}
			if expectedImage != "" && !strings.Contains(ic.Image, expectedImage) {
				GinkgoWriter.Println("Init-container <", initContainerName, "> found but image <", ic.Image, "> does not contain <", expectedImage, ">")
				return false
			}
			GinkgoWriter.Println("Init-container <", initContainerName, "> present with image <", ic.Image, ">")
			return true
		}
		return false
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue(),
		"deployment %s/%s should have init-container %q (image containing %q)", namespace, name, initContainerName, expectedImage)
}

// ExpectDeploymentNotToHaveInitContainer waits until the deployment's pod template no longer
// contains an init-container with the given name (used to assert reconciliation/removal).
func (c *Cluster) ExpectDeploymentNotToHaveInitContainer(ctx context.Context, name string, namespace string, initContainerName string) {
	GinkgoWriter.Println("Waiting for init-container <", initContainerName, "> to be absent from deployment <", name, "> (namespace <", namespace, ">)..")

	Eventually(func() bool {
		spec, ok := c.getDeploymentSpec(ctx, name, namespace)
		if !ok {
			return false
		}
		for _, ic := range spec.InitContainers {
			if ic.Name == initContainerName {
				GinkgoWriter.Println("Init-container <", initContainerName, "> still present, waiting for removal..")
				return false
			}
		}
		return true
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue(),
		"deployment %s/%s should not have init-container %q", namespace, name, initContainerName)
}

// ExpectDeploymentVolume waits until the deployment's pod template contains a volume with the given name.
func (c *Cluster) ExpectDeploymentVolume(ctx context.Context, name string, namespace string, volumeName string) {
	GinkgoWriter.Println("Waiting for volume <", volumeName, "> on deployment <", name, "> (namespace <", namespace, ">)..")

	Eventually(func() bool {
		spec, ok := c.getDeploymentSpec(ctx, name, namespace)
		if !ok {
			return false
		}
		for _, v := range spec.Volumes {
			if v.Name == volumeName {
				return true
			}
		}
		return false
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue(),
		"deployment %s/%s should have volume %q", namespace, name, volumeName)
}

// ExpectDeploymentNotToHaveVolume waits until the deployment's pod template no longer contains
// a volume with the given name.
func (c *Cluster) ExpectDeploymentNotToHaveVolume(ctx context.Context, name string, namespace string, volumeName string) {
	GinkgoWriter.Println("Waiting for volume <", volumeName, "> to be absent from deployment <", name, "> (namespace <", namespace, ">)..")

	Eventually(func() bool {
		spec, ok := c.getDeploymentSpec(ctx, name, namespace)
		if !ok {
			return false
		}
		for _, v := range spec.Volumes {
			if v.Name == volumeName {
				return false
			}
		}
		return true
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue(),
		"deployment %s/%s should not have volume %q", namespace, name, volumeName)
}

// ExpectDeploymentVolumeMount waits until the named container in the deployment's pod template
// mounts the given volume. When mountPath is non-empty, the mount path must match as well.
func (c *Cluster) ExpectDeploymentVolumeMount(ctx context.Context, name string, namespace string, containerName string, volumeName string, mountPath string) {
	GinkgoWriter.Println("Waiting for volume-mount <", volumeName, "> on container <", containerName, "> of deployment <", name, ">..")

	Eventually(func() bool {
		spec, ok := c.getDeploymentSpec(ctx, name, namespace)
		if !ok {
			return false
		}
		for _, ctr := range spec.Containers {
			if ctr.Name != containerName {
				continue
			}
			for _, vm := range ctr.VolumeMounts {
				if vm.Name != volumeName {
					continue
				}
				if mountPath != "" && vm.MountPath != mountPath {
					GinkgoWriter.Println("Volume-mount <", volumeName, "> found but path <", vm.MountPath, "> != <", mountPath, ">")
					return false
				}
				return true
			}
		}
		return false
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue(),
		"container %q in deployment %s/%s should mount volume %q at %q", containerName, namespace, name, volumeName, mountPath)
}

// ExpectDeploymentNotToHaveVolumeMount waits until the named container in the deployment's pod
// template no longer mounts the given volume.
func (c *Cluster) ExpectDeploymentNotToHaveVolumeMount(ctx context.Context, name string, namespace string, containerName string, volumeName string) {
	GinkgoWriter.Println("Waiting for volume-mount <", volumeName, "> to be absent from container <", containerName, "> of deployment <", name, ">..")

	Eventually(func() bool {
		spec, ok := c.getDeploymentSpec(ctx, name, namespace)
		if !ok {
			return false
		}
		for _, ctr := range spec.Containers {
			if ctr.Name != containerName {
				continue
			}
			for _, vm := range ctr.VolumeMounts {
				if vm.Name == volumeName {
					return false
				}
			}
		}
		return true
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue(),
		"container %q in deployment %s/%s should not mount volume %q", containerName, namespace, name, volumeName)
}

func (c *Cluster) ExpectPodsInReadyState(ctx context.Context, labelName string, namespace string) {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())

	Eventually(func() bool {
		pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: labelName})
		if err != nil {
			return false
		}

		// Check if there is at least one pod in the "Running" state.
		for _, pod := range pods.Items {
			GinkgoWriter.Println("Pod name:", pod.Name, "| Pod Status:", pod.Status.Phase)
			if pod.Status.Phase == corev1.PodRunning || pod.Status.Phase == corev1.PodSucceeded {
				return true
			}
		}

		GinkgoWriter.Println("Waiting for a pod with label name:", labelName, "label value:",
			namespace, "to become ready...")
		return false
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue())
}

func (c *Cluster) ExpectDNSToBeResolvableFromHost(ctx context.Context, serviceName string, namespace string) {
	fqdn := fmt.Sprintf("%s.%s.svc.cluster.local", serviceName, namespace)

	GinkgoWriter.Println("Waiting for DNS resolution of <", fqdn, "> from host..")

	Eventually(func() error {
		addrs, err := net.LookupHost(fqdn)
		if err != nil {
			GinkgoWriter.Println("DNS lookup failed for <", fqdn, ">:", err)
			return err
		}
		if len(addrs) == 0 {
			return fmt.Errorf("no addresses resolved for %s", fqdn)
		}
		GinkgoWriter.Println("Resolved <", fqdn, "> to", addrs)
		return nil
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(Succeed(), "DNS resolution of <"+fqdn+"> should succeed")
}

// WaitForNodeToBeReady polls until the node transitions to Ready state.
// This is useful in BeforeSuite to ensure nodes are ready before deploying workloads.
func (c *Cluster) WaitForNodeToBeReady(name string, ctx context.Context) {
	GinkgoWriter.Println("Waiting for node <", name, "> to become Ready...")

	Eventually(func() bool {
		var node corev1.Node
		err := c.Client().Resources().Get(ctx, name, "", &node)
		if err != nil {
			GinkgoWriter.Println("Error getting node <", name, ">:", err)
			return false
		}

		ready := isNodeReady(node)
		if !ready {
			GinkgoWriter.Println("Node <", name, "> is not Ready yet, waiting...")
		}
		return ready
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue(), "Node <%s> should become Ready", name)

	GinkgoWriter.Println("Node <", name, "> is Ready")
}

func (c *Cluster) ExpectNodeToBeReady(name string, ctx context.Context) {
	var node corev1.Node

	Expect(c.Client().Resources().Get(ctx, name, "", &node)).To(Succeed())

	GinkgoWriter.Println("Node <", node.Name, "> found")

	Expect(isNodeReady(node)).To(BeTrue())
}

// ExpectNodeNotToExist verifies that a node with the given name does not exist in the cluster.
func (c *Cluster) ExpectNodeNotToExist(name string, ctx context.Context) {
	var node corev1.Node

	err := c.Client().Resources().Get(ctx, name, "", &node)
	Expect(err).To(HaveOccurred(), "Expected node <%s> to not exist, but it was found", name)
}

func (c *Cluster) ExpectInternetToBeReachableFromPodOfDeployment(deploymentName string, namespace string, proxy string, ctx context.Context) {
	client := c.Client()

	pod, err := determineFirstPodOfDeployment(deploymentName, namespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	command := []string{"curl", "-i", "-m", internetReachabilityCurlMaxTime, "--retry", internetReachabilityCurlRetryCount, "--insecure", "www.msftconnecttest.com/connecttest.txt"}
	if proxy != "" {
		GinkgoWriter.Println("Using proxy for curl")

		command = []string{"curl", "-i", "-m", internetReachabilityCurlMaxTime, "--retry", internetReachabilityCurlRetryCount, "--insecure", "-x", proxy, "www.msftconnecttest.com/connecttest.txt"}
	}

	var stdout, stderr bytes.Buffer

	GinkgoWriter.Println("Executing command <", command, "> ..")

	param := podExecParam{
		Namespace: namespace,
		Pod:       pod.Name,
		Container: deploymentName,
		Command:   command,
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	Eventually(func() error {
		stdout.Reset()
		stderr.Reset()

		err := executeCommandInPod(param)
		if err != nil {
			GinkgoWriter.Println("Command <", param.Command, "> failed with error <", err, ">")
			if stderr.Len() > 0 {
				GinkgoWriter.Println("Command stderr:", stderr.String())
			}
			return err
		}

		httpStatus := strings.Split(stdout.String(), "\n")[0]
		GinkgoWriter.Println("Command <", param.Command, "> executed with http status <", httpStatus, ">")

		if !strings.Contains(httpStatus, "200") {
			return fmt.Errorf("unexpected http status %q (stdout: %q, stderr: %q)", httpStatus, stdout.String(), stderr.String())
		}

		return nil
	}, internetReachabilityCheckTimeout, internetReachabilityCheckPollInterval, ctx).Should(Succeed())
}

func (c *Cluster) waitOptions() []wait.Option {
	return []wait.Option{wait.WithTimeout(c.testStepTimeout), wait.WithInterval(c.testStepPollInterval), wait.WithImmediate()}
}

// WaitForAPIServerReady retries connecting to the Kubernetes API server until it
// responds successfully or the testStepTimeout is exceeded. This is needed after
// operations that may transiently disrupt API server connectivity (e.g., security
// addon enable/disable which installs cert-manager and restarts control-plane components).
func (c *Cluster) WaitForAPIServerReady(ctx context.Context) {
	GinkgoWriter.Println("Waiting for API server to be ready..")

	clientSet, err := kubernetes.NewForConfig(c.Client().Resources().GetConfig())
	Expect(err).ToNot(HaveOccurred())

	Eventually(func() error {
		_, err := clientSet.ServerGroups()
		return err
	}, c.testStepTimeout, 5*time.Second, ctx).Should(Succeed(), "API server should become reachable within %s", c.testStepTimeout)

	GinkgoWriter.Println("API server is ready")
}

func determineFirstPodOfDeployment(deploymentName string, namespace string, client klient.Client, ctx context.Context) (*corev1.Pod, error) {
	pods := &corev1.PodList{}

	err := client.Resources(namespace).List(ctx, pods)
	if err != nil {
		return nil, err
	}
	if pods.Items == nil {
		return nil, fmt.Errorf("no matching Pod found for Deployment '%s' in namespace '%s'", namespace, deploymentName)
	}

	for _, pod := range pods.Items {
		if strings.Contains(pod.Name, deploymentName) {
			GinkgoWriter.Println("Pod <", pod.Name, "> in namespace <", namespace, "> found for Deployment <", deploymentName, ">")
			return &pod, nil
		}
	}

	return nil, fmt.Errorf("no matching Pod found for Deployment '%s' in namespace '%s'", namespace, deploymentName)
}

func contains(slice []string, item string) bool {
	for _, v := range slice {
		if v == item {
			return true
		}
	}
	return false
}

func (c *Cluster) GetPodsGroupedByNode(ctx context.Context, namespace string, nodes []string) map[string][]corev1.Pod {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())

	pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
	Expect(err).NotTo(HaveOccurred(), "Failed to fetch pods")

	podsByNode := make(map[string][]corev1.Pod)
	for _, pod := range pods.Items {
		if contains(nodes, pod.Spec.NodeName) {
			podsByNode[pod.Spec.NodeName] = append(podsByNode[pod.Spec.NodeName], pod)
		}
	}
	return podsByNode
}

func expectCmdExecInPodToSucceed(param podExecParam) {
	Expect(executeCommandInPod(param)).To(Succeed())

	httpStatus := strings.Split(param.Stdout.String(), "\n")[0]

	GinkgoWriter.Println("Command <", param.Command, "> executed with http status <", httpStatus, ">")

	Expect(httpStatus).To(ContainSubstring("200"))
}

func expectCmdExecInPodToBeForbidden(param podExecParam) {
	Expect(executeCommandInPod(param)).To(Succeed())

	httpStatus := strings.Split(param.Stdout.String(), "\n")[0]

	GinkgoWriter.Println("Command <", param.Command, "> executed with http status <", httpStatus, ">")

	//403 is http status forbidden
	Expect(httpStatus).To(ContainSubstring("403"))
}

func executeCommandInPod(param podExecParam) error {
	clientSet, err := kubernetes.NewForConfig(param.Config)
	if err != nil {
		return err
	}

	req := clientSet.CoreV1().RESTClient().Post().
		Resource("pods").
		Name(param.Pod).
		Namespace(param.Namespace).
		SubResource("exec")

	newScheme := runtime.NewScheme()
	if err := corev1.AddToScheme(newScheme); err != nil {
		return err
	}

	parameterCodec := runtime.NewParameterCodec(newScheme)
	req.VersionedParams(&corev1.PodExecOptions{
		Container: param.Container,
		Command:   param.Command,
		Stdout:    true,
		Stderr:    true,
	}, parameterCodec)

	exec, err := remotecommand.NewSPDYExecutor(param.Config, "POST", req.URL())
	if err != nil {
		return err
	}

	return exec.StreamWithContext(param.Ctx, remotecommand.StreamOptions{
		Stdout: param.Stdout,
		Stderr: param.Stderr,
	})
}

func isNodeReady(node corev1.Node) bool {
	for _, cond := range node.Status.Conditions {
		if cond.Type == "Ready" && cond.Status == "True" {
			return true
		}
	}

	return false
}
