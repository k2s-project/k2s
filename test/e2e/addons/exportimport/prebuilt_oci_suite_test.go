// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package exportimport

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestPrebuiltAddonOci(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Prebuilt addon OCI selection", Label("unit", "ci"))
}
