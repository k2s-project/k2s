// SPDX-FileCopyrightText: © 2025 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"os"
	"os/user"
	"path/filepath"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	cn "github.com/k2s-project/k2s/internal/containernetworking"
	"github.com/k2s-project/k2s/internal/logging"
	ve "github.com/k2s-project/k2s/internal/version"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

const (
	maxRetries    = 5
	retryInterval = 2 * time.Second
	cliName       = "l4proxy"
)

func main() {
	var podName string = ""
	var namespace string = ""
	var endpointid string = ""

	versionFlag := cli.NewVersionFlag(cliName)
	flag.StringVar(&podName, "podname", podName, "podname of the running pod")
	flag.StringVar(&namespace, "namespace", namespace, "namespace of the running pod")
	flag.StringVar(&endpointid, "endpointid", endpointid, "endpointid of the running pod")
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}

	if podName == "" || namespace == "" || endpointid == "" {
		flag.PrintDefaults()
		return
	}

	fmt.Printf("%s started, checking if linkerd annotation is set for pod '%s' in namespace '%s'\n", cliName, podName, namespace)

	logDir := filepath.Join(logging.RootLogDir(), cliName)
	logFileName := cliName + "-" + podName + "-" + namespace + ".log"

	logFile, err := logging.SetupDefaultFileLogger(logDir, logFileName, slog.LevelDebug, "component", cliName)
	if err != nil {
		slog.Error("failed to setup file logger", "error", err)
		os.Exit(1)
	}
	defer logFile.Close()

	slog.Debug("Started", "podname", podName, "namespace", namespace)

	currentUser, err := user.Current()
	if err == nil {
		slog.Debug("Current user", "user", currentUser.Username)
	} else {
		slog.Error("failed to determine current user", "error", err)
	}

	os.Unsetenv("HTTP_PROXY")
	os.Unsetenv("HTTPS_PROXY")
	os.Unsetenv("http_proxy")
	os.Unsetenv("https_proxy")

	kubeconfig := "C:\\Windows\\System32\\config\\systemprofile\\config"

	// Build config from the kubeconfig file
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes client configuration: %v", err)
	}

	// Create Kubernetes clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes clientset: %v", err)
	}

	// Check if an annotation exists on the pod in a retry loop
	pod, err := getPodWithRetries(clientset, namespace, podName)
	if err != nil {
		log.Fatalf("Failed to retrieve pod: %v", err)
	}

	// Check if the annotation value is "enabled"
	if pod.Annotations["linkerd.io/inject"] == "enabled" {
		slog.Debug("Annotation 'linkerd.io/inject' is set", "podname", podName, "namespace", namespace)
		log.Println(cliName, "annotation 'linkerd.io/inject' is set for podname:", podName, "namespace:", namespace)
	} else {
		slog.Debug("Annotation 'linkerd.io/inject' is not set", "podname", podName, "namespace", namespace)
		log.Println(cliName, "annotation 'linkerd.io/inject' is not set for podname:", podName, "namespace:", namespace)
		slog.Debug("Deleting L4 policies")

		cn.HnsProxyClearPolicies(endpointid)
	}

	err = logging.CleanLogDir(logDir, 24*time.Hour)
	if err != nil {
		slog.Error("failed to clean up log dir", "error", err)
		os.Exit(1)
	}

	fmt.Printf("%s finished, please checks logs in %s\n", cliName, logFile.Name())
}

func getPodWithRetries(clientset *kubernetes.Clientset, namespace, podname string) (*v1.Pod, error) {
	var pod *v1.Pod
	var err error

	for i := 0; i < maxRetries; i++ {
		internalPod, internalErr := clientset.CoreV1().Pods(namespace).Get(context.Background(), podname, metav1.GetOptions{})
		if internalErr == nil {
			pod = internalPod // Assign to the outer 'pod' variable
			return pod, nil   // Success, return the pod
		}

		log.Printf("Failed to retrieve pod '%s' in namespace '%s' (attempt %d/%d): %v", podname, namespace, i+1, maxRetries, internalErr)
		if i < maxRetries-1 {
			log.Printf("Retrying in %v...", retryInterval)
			time.Sleep(retryInterval)
		}
		err = internalErr // Store the last error
	}

	log.Fatalf("Failed to retrieve pod '%s' in namespace '%s' after %d retries: %v", podname, namespace, maxRetries, err)
	return nil, err // Return the last error if all retries fail
}
