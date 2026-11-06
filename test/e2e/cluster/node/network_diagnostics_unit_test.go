// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: MIT

package node

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestNodeNetworkPodCommandArgs(t *testing.T) {
	for _, container := range []string{"", "curl-sidecar"} {
		args := podCommandArgs("source", container, "curl", "-sS", "http://destination/path")
		want := []string{"exec", "source", "-n", "k2s"}
		if container != "" {
			want = append(want, "-c", container)
		}
		want = append(want, "--", "curl", "-sS", "http://destination/path")
		if !reflect.DeepEqual(args, want) {
			t.Fatalf("container %q: args = %v, want %v", container, args, want)
		}
	}
}

func TestNodeNetworkIndependentProbes(t *testing.T) {
	for _, serviceResult := range []string{`{"spec":{"clusterIP":"172.21.1.50"}}`, "malformed", "query-error"} {
		t.Run(serviceResult, func(t *testing.T) {
			var calls []string
			d := nodeNetworkDiagnostics{
				kubectl: "kubectl",
				sshKey:  `C:\key with spaces`,
				nodes: []clusterconfig.Node{{
					Name: "worker", OS: "linux", Username: "admin", IpAddress: "172.22.6.2",
				}},
				run: func(_ context.Context, executable string, args ...string) (string, error) {
					calls = append(calls, executable+" "+strings.Join(args, " "))
					if strings.HasPrefix(strings.Join(args, " "), "get service ") {
						if serviceResult == "query-error" {
							return "", errors.New("service query failed")
						}
						return serviceResult, nil
					}
					// Probe/SSH failures must not stop subsequent evidence collection.
					return "", errors.New("diagnostic unavailable")
				},
			}
			source := v1.Pod{ObjectMeta: metav1.ObjectMeta{Name: "source"}, Spec: v1.PodSpec{NodeName: "worker"}}
			target := v1.Pod{
				ObjectMeta: metav1.ObjectMeta{Name: "target", Labels: map[string]string{"app": "windows-app"}},
				Spec:       v1.PodSpec{NodeName: "windows"},
				Status:     v1.PodStatus{PodIP: "172.20.1.3"},
			}
			d.collect(context.Background(), source, target, "curl-sidecar")
			output := strings.Join(calls, "\n")
			for _, want := range []string{
				"exec source -n k2s -c curl-sidecar -- curl -sS -i --noproxy * --connect-timeout 3 --max-time 5 http://172.20.1.3:80/windows-app",
				"get endpointslices", "get nodes -o wide", "logs -n kube-flannel", "logs -n kube-system",
				"ssh -n -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5",
				"admin@172.22.6.2 ip -4 address; ip -4 route show table all; ip rule show",
				"ip route get 172.20.1.3", "sudo -n iptables-save -c",
			} {
				if !strings.Contains(output, want) {
					t.Errorf("missing diagnostic %q in:\n%s", want, output)
				}
			}
			hasServiceProbe := strings.Contains(output, "http://172.21.1.50:80/windows-app")
			if hasServiceProbe != strings.HasPrefix(serviceResult, "{") {
				t.Errorf("unexpected Service IP probe presence: %v", hasServiceProbe)
			}
		})
	}
}

func TestNodeNetworkMissingSSHConfiguration(t *testing.T) {
	called := false
	d := nodeNetworkDiagnostics{run: func(context.Context, string, ...string) (string, error) {
		called = true
		return "", nil
	}}
	d.collectLinuxRoutes(context.Background(), "unknown", []string{"172.20.1.3"})
	d.nodes = []clusterconfig.Node{{Name: "worker", OS: "linux", Username: "admin", IpAddress: "172.22.6.2"}}
	d.collectLinuxRoutes(context.Background(), "worker", nil)
	if called {
		t.Fatal("SSH attempted without complete configuration")
	}
}

func TestNodeNetworkCancelledDiagnostic(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := runNodeNetworkDiagnostic(ctx, "must-not-execute"); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cancellation, got %v", err)
	}
}

func TestNodeNetworkDiagnosticOutput(t *testing.T) {
	if os.Getenv("K2S_NETWORK_DIAGNOSTIC_OUTPUT_CHILD") == "1" {
		fmt.Fprintln(os.Stdout, "diagnostic stdout")
		fmt.Fprintln(os.Stderr, "connection failure on stderr")
		os.Exit(7)
	}
	t.Setenv("K2S_NETWORK_DIAGNOSTIC_OUTPUT_CHILD", "1")
	output, err := runNodeNetworkDiagnostic(context.Background(), os.Args[0], "-test.run=^TestNodeNetworkDiagnosticOutput$")
	var exitError *exec.ExitError
	if !errors.As(err, &exitError) || exitError.ExitCode() != 7 {
		t.Fatalf("expected original exit code 7, got %v", err)
	}
	if !strings.Contains(output, "diagnostic stdout") || !strings.Contains(output, "connection failure on stderr") {
		t.Fatalf("diagnostic did not preserve both output streams: %q", output)
	}
}

func TestNodeNetworkDiagnosticDeadline(t *testing.T) {
	if os.Getenv("K2S_NETWORK_DIAGNOSTIC_CHILD") == "1" {
		time.Sleep(time.Minute)
		return
	}
	t.Setenv("K2S_NETWORK_DIAGNOSTIC_CHILD", "1")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	start := time.Now()
	_, err := runNodeNetworkDiagnostic(ctx, os.Args[0], "-test.run=^TestNodeNetworkDiagnosticDeadline$")
	if err == nil || ctx.Err() != context.DeadlineExceeded {
		t.Fatalf("expected timed out subprocess, got err=%v context=%v", err, ctx.Err())
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("diagnostic exceeded bounded shutdown: %v", elapsed)
	}
}
