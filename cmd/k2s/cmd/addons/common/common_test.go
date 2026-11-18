// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common

import (
	"testing"

	"github.com/k2s-project/k2s/internal/core/addons"
)

func TestFindImplementationDefaultsStorageToSmb(t *testing.T) {
	allAddons := addons.Addons{
		{
			Metadata: addons.AddonMetadata{Name: "storage"},
			Spec: addons.AddonSpec{Implementations: []addons.Implementation{
				{Name: "smb", AddonsCmdName: "storage smb"},
				{Name: "ceph", AddonsCmdName: "storage ceph"},
			}},
		},
	}

	addon, impl, err := FindImplementation(allAddons, []string{"storage"})
	if err != nil {
		t.Fatalf("FindImplementation returned error: %v", err)
	}

	if addon.Metadata.Name != "storage" {
		t.Fatalf("expected addon storage, got %q", addon.Metadata.Name)
	}

	if impl.Name != "smb" {
		t.Fatalf("expected default implementation smb, got %q", impl.Name)
	}
}

func TestFindImplementationResolvesExplicitStorageImplementation(t *testing.T) {
	allAddons := addons.Addons{
		{
			Metadata: addons.AddonMetadata{Name: "storage"},
			Spec: addons.AddonSpec{Implementations: []addons.Implementation{
				{Name: "smb", AddonsCmdName: "storage smb"},
				{Name: "ceph", AddonsCmdName: "storage ceph"},
			}},
		},
	}

	_, impl, err := FindImplementation(allAddons, []string{"storage", "ceph"})
	if err != nil {
		t.Fatalf("FindImplementation returned error: %v", err)
	}

	if impl.Name != "ceph" {
		t.Fatalf("expected explicit implementation ceph, got %q", impl.Name)
	}
}
