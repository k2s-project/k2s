// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package dsl

import (
	"context"
	"fmt"
	"strings"
	"sync"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

const testContextName = "k2s-test-context"

var (
	lock            sync.Mutex
	originalContext string
)

func (k2s *K2s) SetWrongK8sContext(ctx context.Context) {
	lock.Lock()
	defer lock.Unlock()

	GinkgoWriter.Println("Setting wrong K8s context")

	kubectl := k2s.suite.Kubectl()

	originalContext = strings.TrimSuffix(kubectl.MustExec(ctx, "config", "current-context"), "\n")

	GinkgoWriter.Println("Saving original K8s context <", originalContext, ">")

	kubectl.MustExec(ctx, "config", "set-context", testContextName)
	kubectl.MustExec(ctx, "config", "use-context", testContextName)

	GinkgoWriter.Println("Wrong K8s context set to <", testContextName, ">")
}

func (k2s *K2s) ResetK8sContext(ctx context.Context) {
	lock.Lock()
	defer lock.Unlock()

	GinkgoWriter.Println("Resetting K8s context to original")

	kubectl := k2s.suite.Kubectl()

	kubectl.MustExec(ctx, "config", "use-context", originalContext)
	kubectl.MustExec(ctx, "config", "delete-context", testContextName)

	GinkgoWriter.Println("K8s context reset to <", originalContext, ">")
}

func (k2s *K2s) VerifyDeploymentToBeReachableFromHost(ctx context.Context, name string, namespace string) {
	url := fmt.Sprintf("http://%s.%s.svc.cluster.local/%s", name, namespace, name)

	_, err := k2s.suite.HttpClient().GetJson(ctx, url)

	Expect(err).ToNot(HaveOccurred())
}

func (k2s *K2s) VerifyDeploymentToBeReachableFromHostAtPort(ctx context.Context, name string, namespace string, port string) {
	url := fmt.Sprintf("http://%s.%s.svc.cluster.local:%s/%s", name, namespace, port, name)

	_, err := k2s.suite.HttpClient().GetJson(ctx, url)

	Expect(err).ToNot(HaveOccurred())
}
