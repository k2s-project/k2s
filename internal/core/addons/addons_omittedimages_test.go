// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package addons

import (
	"os"
	"path/filepath"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// repoRoot resolves the repository root by walking up from this package directory until the shipped
// addon manifest schema is found.
//
// Deriving the root from a fixed number of '..' segments silently breaks when the package is moved:
// loadAddons then resolves the schema outside the repository and every spec below fails during setup
// instead of validating the manifests.
func repoRoot() string {
	dir, err := filepath.Abs(".")
	Expect(err).ToNot(HaveOccurred())

	for {
		if _, err := os.Stat(filepath.Join(dir, "addons", "addon.manifest.schema.json")); err == nil {
			return dir
		}

		parent := filepath.Dir(dir)
		Expect(parent).ToNot(Equal(dir), "could not locate the repository root (addons/addon.manifest.schema.json) above %q", dir)

		dir = parent
	}
}

// loadRealAddons loads (and schema-validates) the addon manifests that ship with the repo.
// This intentionally bypasses the LoadAddons cache so the test always sees the files on disk.
func loadRealAddons() Addons {
	all, err := loadAddons(repoRoot())
	Expect(err).ToNot(HaveOccurred())
	Expect(all).ToNot(BeEmpty())

	return all
}

var _ = Describe("omittedImages in shipped addon manifests", Label("unit", "ci", "addons"), func() {
	// Guards the flag -> image mapping consumed by 'k2s addons import --omit'.
	// Without this, a manifest refactor could silently detach a flag from its images,
	// which would make the importer stop pruning without anybody noticing.

	It("validates all shipped manifests against the schema", func() {
		loadRealAddons()
	})

	It("references only existing files that actually declare images", func() {
		all := loadRealAddons()

		checked := 0

		for _, addon := range all {
			for _, impl := range addon.Spec.Implementations {
				if impl.Commands == nil {
					continue
				}

				for cmdName, cmdConfig := range *impl.Commands {
					if cmdConfig.Cli == nil {
						continue
					}

					for _, flag := range cmdConfig.Cli.Flags {
						if flag.OmittedImages == nil {
							continue
						}

						context := addon.Metadata.Name + "/" + impl.Name + " " + cmdName + " --" + flag.Name
						checked++

						Expect(len(flag.OmittedImages.FromFiles)+len(flag.OmittedImages.Explicit)).
							To(BeNumerically(">", 0), "%s: omittedImages must declare fromFiles or explicit", context)

						for _, explicit := range flag.OmittedImages.Explicit {
							Expect(explicit).To(ContainSubstring(":"),
								"%s: explicit image '%s' must be tagged", context, explicit)
						}

						for _, relativePath := range flag.OmittedImages.FromFiles {
							absolutePath := filepath.Join(impl.Directory, relativePath)

							_, err := os.Stat(absolutePath)
							Expect(err).ToNot(HaveOccurred(),
								"%s: fromFiles entry '%s' does not exist (resolved to '%s')", context, relativePath, absolutePath)

							images, err := extractImagesFromYAMLFile(absolutePath)
							Expect(err).ToNot(HaveOccurred(), "%s: cannot parse '%s'", context, relativePath)
							Expect(images).ToNot(BeEmpty(),
								"%s: '%s' does not declare any image - the mapping would silently prune nothing", context, relativePath)
						}
					}
				}
			}
		}

		Expect(checked).To(BeNumerically(">", 0), "expected at least one flag declaring omittedImages")
	})

	It("declares omittedImages for every omit-style flag", func() {
		all := loadRealAddons()

		missing := []string{}

		for _, addon := range all {
			for _, impl := range addon.Spec.Implementations {
				if impl.Commands == nil {
					continue
				}

				for cmdName, cmdConfig := range *impl.Commands {
					if cmdConfig.Cli == nil {
						continue
					}

					for _, flag := range cmdConfig.Cli.Flags {
						if !strings.HasPrefix(flag.Name, "omit") {
							continue
						}
						if flag.OmittedImages != nil {
							continue
						}

						missing = append(missing, addon.Metadata.Name+"/"+impl.Name+" "+cmdName+" --"+flag.Name)
					}
				}
			}
		}

		Expect(missing).To(BeEmpty(),
			"every 'omit*' flag must declare omittedImages so 'k2s addons import --omit' can skip its images")
	})
})
