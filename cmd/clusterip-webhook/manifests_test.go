// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"maps"
	"net"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	"sigs.k8s.io/yaml"
)

const (
	manifestDir = "../../lib/manifests/clusterip-webhook"

	// imagePullScript pulls the webhook image into the control plane image.
	imagePullScript = "../../lib/modules/windows/node/k2s.node.module/linuxnode/distros/common-setup.module.psm1"
)

var _ = Describe("webhook manifests", func() {
	var (
		deployment appsv1.Deployment
		service    corev1.Service
		webhooks   admissionregistrationv1.MutatingWebhookConfiguration
		initCert   corev1.Container
		webhook    corev1.Container
	)

	BeforeEach(func() {
		deployment, service, webhooks = appsv1.Deployment{}, corev1.Service{}, admissionregistrationv1.MutatingWebhookConfiguration{}
		loadManifest("deployment.yaml", &deployment, &service)
		loadManifest("webhook-config.yaml", &webhooks)

		pod := deployment.Spec.Template.Spec
		Expect(pod.InitContainers).To(HaveLen(1))
		Expect(pod.Containers).To(HaveLen(1))
		initCert, webhook = pod.InitContainers[0], pod.Containers[0]
	})

	It("give the webhook the public client CA certificate and no volume that could hold a private key", func() {
		clientCAFile := argument(webhook, "client-ca-file")
		mounts := slices.DeleteFunc(slices.Clone(webhook.VolumeMounts), func(mount corev1.VolumeMount) bool {
			return mount.MountPath != path.Dir(clientCAFile)
		})
		Expect(mounts).To(HaveLen(1))
		Expect(mounts[0].ReadOnly).To(BeTrue())
		Expect(initCert.VolumeMounts).NotTo(ContainElement(HaveField("Name", mounts[0].Name)))

		for _, volume := range deployment.Spec.Template.Spec.Volumes {
			if volume.Name == mounts[0].Name {
				Expect(volume.ConfigMap).NotTo(BeNil())
				Expect(volume.ConfigMap.Name).To(Equal("clusterip-webhook-client-ca"))
				Expect(volume.ConfigMap.Optional).To(BeNil(), "the Pod must not start without the client CA")
				Expect(volume.ConfigMap.Items).To(Equal([]corev1.KeyToPath{{Key: "ca.crt", Path: path.Base(clientCAFile)}}))
			}

			source := volume.VolumeSource
			source.EmptyDir, source.ConfigMap = nil, nil
			Expect(source).To(BeZero(), "volume %s", volume.Name)
		}
	})

	It("probe the plain HTTP health listener, because the kubelet has no client certificate", func() {
		Expect(containerPort(webhook, "https")).To(Equal(portOf(argument(webhook, "addr"))))
		Expect(containerPort(webhook, "health")).To(Equal(portOf(argument(webhook, "health-addr"))))
		Expect(containerPort(webhook, "health")).NotTo(Equal(containerPort(webhook, "https")))

		for _, probe := range []*corev1.Probe{webhook.LivenessProbe, webhook.ReadinessProbe} {
			Expect(probe).NotTo(BeNil())
			Expect(probe.HTTPGet).NotTo(BeNil())
			Expect(probe.HTTPGet.Path).To(Equal("/healthz"))
			Expect(probe.HTTPGet.Port).To(Equal(intstr.FromString("health")))
			Expect(probe.HTTPGet.Scheme).To(Equal(corev1.URISchemeHTTP))
		}
	})

	It("call the admission endpoints under the host name of the kube-apiserver client certificate", func() {
		Expect(service.Name + "." + service.Namespace + ".svc").To(Equal(webhookHost))
		Expect(argument(initCert, "service-name")).To(Equal(service.Name))
		Expect(argument(initCert, "namespace")).To(Equal(service.Namespace))
		for label, value := range service.Spec.Selector {
			Expect(deployment.Spec.Template.Labels).To(HaveKeyWithValue(label, value))
		}
		Expect(service.Spec.Ports).To(HaveLen(1))
		Expect(service.Spec.Ports[0].TargetPort).To(Equal(intstr.FromInt32(containerPort(webhook, "https"))))

		var endpoints []string
		for _, hook := range webhooks.Webhooks {
			reference := hook.ClientConfig.Service
			Expect(hook.ClientConfig.URL).To(BeNil(), hook.Name)
			Expect(reference).NotTo(BeNil(), hook.Name)
			Expect(reference.Name).To(Equal(service.Name), hook.Name)
			Expect(reference.Namespace).To(Equal(service.Namespace), hook.Name)
			// The kube-apiserver finds a client certificate that is registered
			// under the host name without a port for port 443 only.
			Expect(reference.Port).To(HaveValue(BeEquivalentTo(443)), hook.Name)
			Expect(service.Spec.Ports[0].Port).To(Equal(*reference.Port), hook.Name)
			Expect(reference.Path).NotTo(BeNil(), hook.Name)
			endpoints = append(endpoints, *reference.Path)

			// The serving CA is injected at run time. The client CA never belongs here.
			Expect(hook.ClientConfig.CABundle).To(BeEmpty(), hook.Name)
		}
		Expect(endpoints).To(ConsistOf(slices.Collect(maps.Keys(admissionRequests()))))
	})

	It("use one image for both containers and for the image pulled into the control plane", func() {
		Expect(initCert.Image).To(Equal(webhook.Image))

		script, err := os.ReadFile(filepath.FromSlash(imagePullScript))
		Expect(err).NotTo(HaveOccurred())
		pulled := regexp.MustCompile(`crictl pull (\S*/clusterip-webhook:[^\s']+)`).FindAllStringSubmatch(string(script), -1)
		Expect(pulled).To(HaveLen(1))
		Expect(pulled[0][1]).To(Equal(webhook.Image))
	})

	It("pass only arguments that the webhook accepts", func() {
		for _, container := range []corev1.Container{initCert, webhook} {
			exitCode, output := runWebhook(append(slices.Clone(container.Args), "--version")...)

			Expect(exitCode).To(BeZero(), "%s: %s", container.Name, output)
		}
	})
})

// loadManifest decodes the documents of a webhook manifest into the given
// objects and fails on fields that the Kubernetes API does not know.
func loadManifest(name string, objects ...any) {
	GinkgoHelper()

	data, err := os.ReadFile(filepath.Join(filepath.FromSlash(manifestDir), name))
	Expect(err).NotTo(HaveOccurred())

	var documents [][]byte
	reader := utilyaml.NewYAMLReader(bufio.NewReader(bytes.NewReader(data)))
	for {
		document, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		Expect(err).NotTo(HaveOccurred())

		var content map[string]any
		Expect(yaml.Unmarshal(document, &content)).To(Succeed(), name)
		if len(content) > 0 {
			documents = append(documents, document)
		}
	}

	Expect(documents).To(HaveLen(len(objects)), name)
	for i, object := range objects {
		Expect(yaml.UnmarshalStrict(documents[i], object)).To(Succeed(), name)
	}
}

// argument returns the value of the --name=value argument of a container.
func argument(container corev1.Container, name string) string {
	GinkgoHelper()

	for _, arg := range container.Args {
		if value, found := strings.CutPrefix(arg, "--"+name+"="); found {
			return value
		}
	}
	Fail(fmt.Sprintf("container %s has no argument --%s", container.Name, name))
	return ""
}

func containerPort(container corev1.Container, name string) int32 {
	GinkgoHelper()

	for _, port := range container.Ports {
		if port.Name == name {
			return port.ContainerPort
		}
	}
	Fail(fmt.Sprintf("container %s has no port %s", container.Name, name))
	return 0
}

// portOf returns the port of a listen address such as ":8443".
func portOf(addr string) int32 {
	GinkgoHelper()

	_, port, err := net.SplitHostPort(addr)
	Expect(err).NotTo(HaveOccurred())
	number, err := strconv.ParseInt(port, 10, 32)
	Expect(err).NotTo(HaveOccurred())
	return int32(number)
}
