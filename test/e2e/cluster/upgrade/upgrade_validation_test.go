// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package upgrade

import (
	"context"
	"strings"
	"testing"

	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const (
	albumApp1Name   = "albums-win1"
	albumApp2Name   = "albums-win2"
	albumLinux1Name = "albums-linux1"
	albumLinux2Name = "albums-linux2"
	albumsNamespace = "k2s"
	albumsImageRepo = "shsk2s.azurecr.io/example.albums-golang-win"
)

var (
	suite *framework.K2sTestSuite
	k2s   *dsl.K2s
)

func TestUpgradeValidation(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Upgrade User Application Validation Tests", Label("upgrade-user-application-validation"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning)
	k2s = dsl.NewK2s(suite)
})

var _ = Describe("Upgrade Validation", func() {
	Describe("Image Preservation", Label("upgrade-image-validation"), func() {

		It("control-plane node reports Debian 13 osImage", func(ctx SpecContext) {
			controlPlaneNode := getControlPlaneNode(ctx)
			if controlPlaneNode == "" {
				Skip("No control-plane node found")
			}

			osImage := strings.TrimSpace(suite.Kubectl().MustExec(
				ctx,
				"get", "node", controlPlaneNode,
				"-o", "jsonpath={.status.nodeInfo.osImage}",
			))

			Expect(osImage).To(ContainSubstring("Debian GNU/Linux 13"),
				"control-plane node %s should run Debian 13, actual osImage=%q", controlPlaneNode, osImage)
		})

		It("user application images are preserved after upgrade", func(ctx SpecContext) {
			output := suite.K2sCli().MustExec(ctx, "image", "ls")

			// Only check for images, not specific tags
			expectedImages := []string{
				albumsImageRepo,
				// Add other images to check here
			}

			for _, image := range expectedImages {
				Expect(output).To(ContainSubstring(image),
					"Image '%s' is missing after upgrade", image)
			}
		})
	})

	Describe("Application Validation", Label("upgrade-app-validation"), func() {

		It("albums namespace contains albums-win1 and albums-win2 pods", func(ctx SpecContext) {
			client := suite.Cluster().Client()
			clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
			Expect(err).To(BeNil(), "UPGRADE VALIDATION ERROR: Cannot access Kubernetes API after upgrade")

			// Check namespace exists
			_, err = clientSet.CoreV1().Namespaces().Get(ctx, albumsNamespace, metav1.GetOptions{})
			Expect(err).To(BeNil(), "user namespace '%s' should be preserved after upgrade", albumsNamespace)

			// Check for albums-win1 pods
			pods1, err := clientSet.CoreV1().Pods(albumsNamespace).List(ctx, metav1.ListOptions{
				LabelSelector: "app=" + albumApp1Name,
			})
			Expect(err).NotTo(HaveOccurred(), "Cannot list pods in namespace '%s' after upgrade", albumsNamespace)

			Expect(len(pods1.Items)).To(BeNumerically(">", 0),
				"expected to find pods with label 'app=%s' in namespace '%s'", albumApp1Name, albumsNamespace)

			// Check for albums-win2 pods
			pods2, err := clientSet.CoreV1().Pods(albumsNamespace).List(ctx, metav1.ListOptions{
				LabelSelector: "app=" + albumApp2Name,
			})
			Expect(err).NotTo(HaveOccurred(), "Cannot list pods in namespace '%s' after upgrade", albumsNamespace)

			Expect(len(pods2.Items)).To(BeNumerically(">", 0),
				"expected to find pods with label 'app=%s' in namespace '%s'", albumApp2Name, albumsNamespace)
		})

		It("all baseline application deployments are available after upgrade", func(ctx SpecContext) {
			for _, deploymentName := range []string{albumLinux1Name, albumLinux2Name, albumApp1Name, albumApp2Name} {
				suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, albumsNamespace)
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, albumsNamespace)
			}
		})
	})

	Describe("Resource Validation", Label("upgrade-resource-validation"), func() {
		It("user deployments are preserved and available after upgrade", func(ctx SpecContext) {
			userDeployments := map[string]string{
				albumApp1Name: albumsNamespace,
				albumApp2Name: albumsNamespace,
			}

			for deploymentName, namespace := range userDeployments {

				client := suite.Cluster().Client()
				clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
				Expect(err).To(BeNil())

				// Check if namespace exists
				_, err = clientSet.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
				Expect(err).To(BeNil(), "namespace '%s' for deployment '%s' not found", namespace, deploymentName)

				// Check if deployment exists
				deployment, err := clientSet.AppsV1().Deployments(namespace).Get(ctx, deploymentName, metav1.GetOptions{})
				Expect(err).To(BeNil(), "deployment '%s' not found in namespace '%s'", deploymentName, namespace)

				Expect(deployment.Spec.Replicas).ToNot(BeNil(),
					"deployment '%s' in namespace '%s' has nil replicas", deploymentName, namespace)
			}
		})

		It("user services are preserved and accessible after upgrade", func(ctx SpecContext) {

			client := suite.Cluster().Client()
			clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
			Expect(err).To(BeNil(), "UPGRADE VALIDATION ERROR: Cannot connect to Kubernetes API after upgrade")

			// Check that albums namespace exists and has services
			_, err = clientSet.CoreV1().Namespaces().Get(ctx, albumsNamespace, metav1.GetOptions{})
			Expect(err).To(BeNil(), "user namespace '%s' not found", albumsNamespace)

			services, err := clientSet.CoreV1().Services(albumsNamespace).List(ctx, metav1.ListOptions{})
			Expect(err).NotTo(HaveOccurred(), "Cannot list services in namespace '%s'", albumsNamespace)

			// Expect at least two user services to exist (albums-win1 and albums-win2)
			Expect(len(services.Items)).To(BeNumerically(">=", 2), "expected at least 2 services in namespace '%s' after upgrade", albumsNamespace)

			// Validate that services have proper configuration
			for _, service := range services.Items {
				Expect(service.Spec.ClusterIP).ToNot(BeEmpty(), "service '%s' is missing its ClusterIP", service.Name)
			}
		})
	})

	Describe("Addon Preservation", Label("upgrade-addon-validation"), func() {
		It("metrics addon is re-enabled and reported as enabled after upgrade", func(ctx SpecContext) {
			if !k2s.IsAddonEnabled("metrics") {
				Skip("metrics addon was not enabled before upgrade, skipping re-enable check")
			}

			// Verify setup.json reflects the addon as enabled
			k2s.VerifyAddonIsEnabled("metrics")

			// Verify the CLI also reports the addon as enabled
			output := suite.K2sCli().MustExec(ctx, "addons", "status", "metrics")
			Expect(output).To(MatchRegexp(`Addon .+metrics.+ is .+enabled.+`),
				"metrics addon should be reported as enabled after upgrade")
		})
	})
})

func isPodReady(pod corev1.Pod) bool {
	for _, condition := range pod.Status.Conditions {
		if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func getPodRestarts(pod corev1.Pod) int32 {
	var restarts int32 = 0
	for _, containerStatus := range pod.Status.ContainerStatuses {
		restarts += containerStatus.RestartCount
	}
	return restarts
}

func getControlPlaneNode(ctx context.Context) string {
	output := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "node-role.kubernetes.io/control-plane", "-o", "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}")
	output = strings.TrimSpace(output)
	if output != "" {
		return strings.Split(output, "\n")[0]
	}

	output = suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "node-role.kubernetes.io/master", "-o", "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}")
	output = strings.TrimSpace(output)
	if output != "" {
		return strings.Split(output, "\n")[0]
	}

	return ""
}
