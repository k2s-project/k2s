//go:build linux

// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("linuxNodeProvider", Label("unit"), func() {
	validAdd := NodeAddConfig{IpAddress: "10.10.0.20", UserName: "debian", NodePackagePath: "/tmp/node.zip"}

	Describe("Add", func() {
		It("requires IP address and user", func() {
			p := &linuxNodeProvider{installDir: GinkgoT().TempDir()}

			Expect(p.Add(NodeAddConfig{UserName: "debian", NodePackagePath: "/tmp/node.zip"})).To(MatchError(ContainSubstring("--ip-addr")))
			Expect(p.Add(NodeAddConfig{IpAddress: "10.10.0.20", NodePackagePath: "/tmp/node.zip"})).To(MatchError(ContainSubstring("--username")))
		})

		It("runs Add.sh online when no node package is given", func() {
			installDir := installFakeNodeScript("Add.sh", 0)
			argsFile := filepath.Join(GinkgoT().TempDir(), "args")
			script := filepath.Join(installDir, "lib", "scripts", "linux", "debian", "worker", "bare-metal", "Add.sh")
			Expect(os.WriteFile(script, []byte(`printf '%s ' "$@" > "`+argsFile+`"`), 0o600)).To(Succeed())
			p := &linuxNodeProvider{installDir: installDir, configDir: "/var/lib/k2s"}

			Expect(p.Add(NodeAddConfig{IpAddress: "10.10.0.20", UserName: "debian"})).To(Succeed())

			args, err := os.ReadFile(argsFile)
			Expect(err).ToNot(HaveOccurred())
			Expect(strings.TrimSpace(string(args))).To(Equal("--ip-address 10.10.0.20 --user debian --install-dir " + installDir + " --config-dir /var/lib/k2s"))
		})

		It("fails when Add.sh is missing", func() {
			p := &linuxNodeProvider{installDir: GinkgoT().TempDir()}

			Expect(p.Add(validAdd)).To(MatchError(ContainSubstring("Add.sh")))
		})

		It("reports a script failure with the script's last error line", func() {
			p := &linuxNodeProvider{installDir: installFakeNodeScript("Add.sh", 1)}

			err := p.Add(validAdd)

			var failure *ProviderFailure
			Expect(errors.As(err, &failure)).To(BeFalse())
			Expect(err).To(MatchError(And(ContainSubstring("10.10.0.20"), ContainSubstring("node rejected"), ContainSubstring("see log file"))))
		})
	})

	DescribeTable("reports a rejected node as warning",
		func(script string, exitCode int, code string, call func(*linuxNodeProvider) error) {
			p := &linuxNodeProvider{installDir: installFakeNodeScript(script, exitCode)}

			err := call(p)

			var failure *ProviderFailure
			Expect(errors.As(err, &failure)).To(BeTrue(), "got %v", err)
			Expect(failure.Severity).To(Equal(SeverityWarning))
			Expect(failure.Code).To(Equal(code))
			Expect(failure.Message).To(Equal("node rejected"))
		},
		Entry("unsupported OS", "Add.sh", 3, "node-os-not-supported", func(p *linuxNodeProvider) error { return p.Add(validAdd) }),
		Entry("already existing node", "Add.sh", 4, "node-already-exists", func(p *linuxNodeProvider) error { return p.Add(validAdd) }),
		Entry("unknown node", "Remove.sh", 5, "node-not-found", func(p *linuxNodeProvider) error {
			return p.Remove(NodeRemoveConfig{NodeName: "worker1"})
		}),
	)

	Describe("Remove", func() {
		It("requires a node name", func() {
			p := &linuxNodeProvider{installDir: installFakeNodeScript("Remove.sh", 0)}

			Expect(p.Remove(NodeRemoveConfig{})).To(MatchError(ContainSubstring("--name")))
		})
	})

	Describe("Start and Stop", func() {
		It("reject nodes that are not Linux workers", func() {
			p := &linuxNodeProvider{installDir: installFakeNodeScript("Start.sh", 0)}

			Expect(p.Start(NodeStartConfig{NodeName: "win1", Role: "worker", OS: "windows"})).To(MatchError(ErrNotSupported))
			Expect(p.Stop(NodeStopConfig{NodeName: "cp1", Role: "control-plane", OS: "linux"})).To(MatchError(ErrNotSupported))
		})

		It("passes the NotReady wait to Stop.sh", func() {
			installDir := installFakeNodeScript("Stop.sh", 0)
			argsFile := filepath.Join(GinkgoT().TempDir(), "args")
			script := filepath.Join(installDir, "lib", "scripts", "linux", "debian", "worker", "bare-metal", "Stop.sh")
			Expect(os.WriteFile(script, []byte(`printf '%s ' "$@" > "`+argsFile+`"`), 0o600)).To(Succeed())
			p := &linuxNodeProvider{installDir: installDir, configDir: "/var/lib/k2s"}

			Expect(p.Stop(NodeStopConfig{NodeName: "worker1", Role: "worker", OS: "linux", WaitForNotReady: true})).To(Succeed())

			args, err := os.ReadFile(argsFile)
			Expect(err).ToNot(HaveOccurred())
			Expect(strings.TrimSpace(string(args))).To(Equal("--name worker1 --wait-for-not-ready --install-dir " + installDir + " --config-dir /var/lib/k2s"))
		})
	})
})

var _ = Describe("worker-node.module.sh", Label("unit"), func() {
	var configDir string

	BeforeEach(func() {
		configDir = GinkgoT().TempDir()
	})

	It("adds cluster.json entries in the schema of clusterconfig", func() {
		snippet := `k2s_node_configure debian 10.10.0.20 key && k2s_node_config_add "$1/cluster.json" worker1 &&
k2s_node_configure admin 10.10.0.21 key && k2s_node_config_add "$1/cluster.json" worker2`

		_, err := runNodeModuleFunction(nil, snippet, configDir)
		Expect(err).ToNot(HaveOccurred())

		cluster, err := clusterconfig.Read(configDir)
		Expect(err).ToNot(HaveOccurred())
		Expect(cluster).ToNot(BeNil())
		Expect(cluster.Nodes).To(Equal([]clusterconfig.Node{
			{Name: "worker1", IpAddress: "10.10.0.20", Username: "debian", NodeType: clusterconfig.NodeTypeHost, Role: clusterconfig.RoleWorker, OS: clusterconfig.OsTypeLinux},
			{Name: "worker2", IpAddress: "10.10.0.21", Username: "admin", NodeType: clusterconfig.NodeTypeHost, Role: clusterconfig.RoleWorker, OS: clusterconfig.OsTypeLinux},
		}))
	})

	It("reads and removes a cluster.json entry and keeps the others", func() {
		content := `{"nodes":[{"Name":"Worker1","IpAddress":"10.10.0.20","Username":"debian"},{"Name":"worker2","IpAddress":"10.10.0.21","Username":"admin"}]}`
		Expect(os.WriteFile(filepath.Join(configDir, "cluster.json"), []byte(content), 0o600)).To(Succeed())

		entry, err := runNodeModuleFunction(nil, `k2s_node_config_get "$1/cluster.json" worker1 && k2s_node_config_remove "$1/cluster.json" worker1`, configDir)
		Expect(err).ToNot(HaveOccurred())
		Expect(entry).To(Equal("10.10.0.20 debian"))

		cluster, err := clusterconfig.Read(configDir)
		Expect(err).ToNot(HaveOccurred())
		Expect(cluster.Nodes).To(HaveLen(1))
		Expect(cluster.Nodes[0].Name).To(Equal("worker2"))
	})

	It("writes the install proxy to proxy.conf and reads it back", func() {
		snippet := `source "$K2S_INSTALL_DIR/lib/modules/linux/infra/proxy.sh"
K2S_CONFIG_DIR="$1" K2S_PROXY='http://user:secret@proxy.example:3128' K2S_NO_PROXY='localhost,.svc' k2s_proxy_config_write
stat -c %a "$1/proxy.conf"
k2s_proxy_config_http "$1"
k2s_proxy_config_http "$1/missing"`

		out, err := runNodeModuleFunction(nil, snippet, configDir)

		Expect(err).ToNot(HaveOccurred())
		Expect(out).To(Equal("600\nhttp://user:secret@proxy.example:3128"))
		content, err := os.ReadFile(filepath.Join(configDir, "proxy.conf"))
		Expect(err).ToNot(HaveOccurred())
		Expect(string(content)).To(Equal("http_proxy=http://user:secret@proxy.example:3128\nhttps_proxy=http://user:secret@proxy.example:3128\nno_proxy=localhost,.svc\n"))
	})

	It("masks the credentials of a proxy URL in the output", func() {
		out, err := runNodeModuleFunction(nil, `printf '%s\n' "proxy: $1" "other line" | k2s_node_mask_proxy "$1"; printf '%s\n' "plain: $2" | k2s_node_mask_proxy "$2"`,
			"http://user:secret@proxy.example:3128", "http://proxy.example:3128")

		Expect(err).ToNot(HaveOccurred())
		Expect(out).To(Equal("proxy: http://***@proxy.example:3128\nother line\nplain: http://proxy.example:3128"))
	})

	DescribeTable("rejects nodes that are known to the cluster or the configuration",
		func(node string, wantExitCode int) {
			Expect(os.WriteFile(filepath.Join(configDir, "cluster.json"), []byte(`{"nodes":[{"Name":"configured"}]}`), 0o600)).To(Succeed())
			stubs := map[string]string{"kubectl": `printf '%s' 'control-plane joined'`}

			_, err := runNodeModuleFunction(stubs, `k2s_node_check_not_in_cluster "$1" "$2/cluster.json"`, node, configDir)

			Expect(exitCode(err)).To(Equal(wantExitCode), "got %v", err)
		},
		Entry("node in the cluster", "joined", 4),
		Entry("node in cluster.json", "configured", 4),
		Entry("new node", "new", 0),
	)

	Describe("k2s_node_host_ip", func() {
		It("prints the host address for a directly connected node", func() {
			stubs := map[string]string{"ip": `printf '%s\n' '10.10.0.20 dev eth0 src 10.10.0.5 uid 0'`}

			hostIP, err := runNodeModuleFunction(stubs, `k2s_node_configure debian 10.10.0.20 key && k2s_node_host_ip`)

			Expect(err).ToNot(HaveOccurred())
			Expect(hostIP).To(Equal("10.10.0.5"))
		})

		It("rejects a node behind a router", func() {
			stubs := map[string]string{"ip": `printf '%s\n' '10.20.0.20 via 10.10.0.1 dev eth0 src 10.10.0.5 uid 0'`}

			_, err := runNodeModuleFunction(stubs, `k2s_node_configure debian 10.20.0.20 key && k2s_node_host_ip`)

			Expect(err).To(MatchError(ContainSubstring("layer-2")))
		})
	})

	It("labels an added node as worker", func() {
		calls := filepath.Join(GinkgoT().TempDir(), "calls")
		stubs := map[string]string{"kubectl": `printf '%s\n' "$*" >> "` + calls + `"`}

		_, err := runNodeModuleFunction(stubs, `k2s_node_label_worker worker1`)

		Expect(err).ToNot(HaveOccurred())
		commands, err := os.ReadFile(calls)
		Expect(err).ToNot(HaveOccurred())
		Expect(strings.TrimSpace(string(commands))).To(Equal("label node worker1 kubernetes.io/role=worker --overwrite"))
	})

	DescribeTable("k2s_node_remove_from_cluster",
		func(kubectl string, wantErr bool, wantCommands string) {
			calls := filepath.Join(GinkgoT().TempDir(), "calls")
			stubs := map[string]string{"kubectl": `printf '%s ' "$1" >> "` + calls + `"` + "\n" + kubectl}

			_, err := runNodeModuleFunction(stubs, `k2s_node_remove_from_cluster worker1`)

			commands, _ := os.ReadFile(calls)
			Expect(err != nil).To(Equal(wantErr), "got %v", err)
			Expect(strings.TrimSpace(string(commands))).To(Equal(wantCommands))
		},
		Entry("skips a node that is not in the cluster", `[[ $1 != get ]] || exit 1`, false, "get"),
		Entry("deletes the node when draining fails", `[[ $1 != drain ]] || exit 1`, false, "get drain delete"),
		Entry("fails when deleting fails", `[[ $1 != delete ]] || exit 1`, true, "get drain delete"),
	)
})

func installFakeNodeScript(name string, exitCode int) string {
	installDir := GinkgoT().TempDir()
	scriptDir := filepath.Join(installDir, "lib", "scripts", "linux", "debian", "worker", "bare-metal")
	Expect(os.MkdirAll(scriptDir, 0o700)).To(Succeed())
	script := "printf '%s\\n' 'first error' 'node rejected' >&2\nexit " + strconv.Itoa(exitCode) + "\n"
	Expect(os.WriteFile(filepath.Join(scriptDir, name), []byte(script), 0o600)).To(Succeed())
	return installDir
}

func runNodeModuleFunction(stubs map[string]string, snippet string, args ...string) (string, error) {
	for _, tool := range []string{"bash", "jq"} {
		if _, err := exec.LookPath(tool); err != nil {
			Skip(tool + " is not available")
		}
	}
	stubDir := GinkgoT().TempDir()
	for name, body := range stubs {
		Expect(os.WriteFile(filepath.Join(stubDir, name), []byte("#!/usr/bin/env bash\n"+body+"\n"), 0o700)).To(Succeed())
	}
	script := "set -euo pipefail\nsource \"$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh\"\nsource \"$0\"\n" + snippet
	module := filepath.Join(repositoryRoot, "lib/modules/linux/node/worker-node.module.sh")
	cmd := exec.Command("bash", append([]string{"-c", script, module}, args...)...)
	cmd.Env = append(os.Environ(), "PATH="+stubDir+string(os.PathListSeparator)+os.Getenv("PATH"),
		"K2S_INSTALL_DIR="+repositoryRoot, "K2S_LOG_FILE="+filepath.Join(GinkgoT().TempDir(), "k2s.log"))
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if err != nil {
		err = fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(stdout.String()), err
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	if exitErr, ok := errors.AsType[*exec.ExitError](err); ok {
		return exitErr.ExitCode()
	}
	return -1
}
