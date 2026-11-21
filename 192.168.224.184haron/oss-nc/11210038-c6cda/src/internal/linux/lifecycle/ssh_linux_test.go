// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package lifecycle

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("ssh.sh", Label("unit"), func() {
	const sshDirRelativeToHome = "custom/ssh"
	const keySubDir = "keys"
	const keyFileName = "test_key"

	var homeDir, installDir, keyDir string

	BeforeEach(func() {
		homeDir = GinkgoT().TempDir()
		keyDir = filepath.Join(homeDir, sshDirRelativeToHome, keySubDir)

		installDir = GinkgoT().TempDir()
		Expect(os.MkdirAll(filepath.Join(installDir, "cfg"), 0o755)).To(Succeed())
		config := `{"configDir": {"ssh": "~/` + sshDirRelativeToHome + `"}, "sshKey": {"subDir": "` + keySubDir + `", "fileName": {"windows": "other_key", "linux": "` + keyFileName + `"}}}`
		Expect(os.WriteFile(filepath.Join(installDir, "cfg", "config.json"), []byte(config), 0o644)).To(Succeed())
	})

	run := func(body string) (stdOut string, err error) {
		logging, absErr := filepath.Abs(linuxModulePath(filepath.Join("common", "logging.sh")))
		Expect(absErr).ToNot(HaveOccurred())
		module, absErr := filepath.Abs(linuxModulePath(filepath.Join("infra", "ssh.sh")))
		Expect(absErr).ToNot(HaveOccurred())

		cmd := exec.Command("bash", "-c", "set -euo pipefail\nsource \"$1\"\nsource \"$2\"\n"+body, "bash", logging, module)
		cmd.Env = append(os.Environ(),
			"HOME="+homeDir,
			"K2S_INSTALL_DIR="+installDir,
			"K2S_LOG_FILE="+filepath.Join(GinkgoT().TempDir(), "k2s.log"),
			"K2S_SHOW_LOGS=")
		var out bytes.Buffer
		cmd.Stdout = &out
		cmd.Stderr = GinkgoWriter
		err = cmd.Run()
		return strings.TrimSpace(out.String()), err
	}

	Describe("k2s_ssh_private_key", func() {
		It("resolves the configured Linux key against the home dir of the invoking user", func() {
			out, err := run("k2s_ssh_private_key")

			Expect(err).ToNot(HaveOccurred())
			Expect(out).To(Equal(filepath.Join(keyDir, keyFileName)))
		})

		It("fails if no Linux key name is configured", func() {
			Expect(os.WriteFile(filepath.Join(installDir, "cfg", "config.json"), []byte(`{"configDir": {"ssh": "~/x"}, "sshKey": {"subDir": "k"}}`), 0o644)).To(Succeed())

			_, err := run("k2s_ssh_private_key")

			Expect(err).To(HaveOccurred())
		})
	})

	Describe("k2s_ssh_ensure_key", func() {
		It("creates the K2s key pair with restrictive permissions", func() {
			_, err := run("k2s_ssh_ensure_key")

			Expect(err).ToNot(HaveOccurred())
			key, statErr := os.Stat(filepath.Join(keyDir, keyFileName))
			Expect(statErr).ToNot(HaveOccurred())
			Expect(key.Mode().Perm()).To(Equal(os.FileMode(0o600)))
			Expect(filepath.Join(keyDir, keyFileName+".pub")).To(BeAnExistingFile())
		})

		It("keeps an existing key pair", func() {
			_, err := run("k2s_ssh_ensure_key")
			Expect(err).ToNot(HaveOccurred())
			publicKeyPath := filepath.Join(keyDir, keyFileName+".pub")
			before, err := os.ReadFile(publicKeyPath)
			Expect(err).ToNot(HaveOccurred())

			_, err = run("k2s_ssh_ensure_key")

			Expect(err).ToNot(HaveOccurred())
			after, err := os.ReadFile(publicKeyPath)
			Expect(err).ToNot(HaveOccurred())
			Expect(after).To(Equal(before))
		})
	})

	Describe("k2s_ssh_require_key", func() {
		It("succeeds if the key pair exists", func() {
			_, err := run("k2s_ssh_ensure_key && k2s_ssh_require_key")

			Expect(err).ToNot(HaveOccurred())
		})

		It("fails if the key pair is missing", func() {
			_, err := run("k2s_ssh_require_key")

			Expect(err).To(HaveOccurred())
		})
	})

	Describe("k2s_ssh_remove_key", func() {
		It("removes the key pair and the then empty key dir", func() {
			_, err := run("k2s_ssh_ensure_key && k2s_ssh_remove_key")

			Expect(err).ToNot(HaveOccurred())
			Expect(keyDir).ToNot(BeADirectory())
			Expect(filepath.Dir(keyDir)).To(BeADirectory())
		})

		It("keeps the key dir if it contains other files", func() {
			_, err := run("k2s_ssh_ensure_key && touch \"$(k2s_ssh_key_dir)/other\" && k2s_ssh_remove_key")

			Expect(err).ToNot(HaveOccurred())
			Expect(filepath.Join(keyDir, keyFileName)).ToNot(BeAnExistingFile())
			Expect(filepath.Join(keyDir, "other")).To(BeAnExistingFile())
		})

		It("succeeds if there is no key", func() {
			_, err := run("k2s_ssh_remove_key")

			Expect(err).ToNot(HaveOccurred())
		})
	})
})
