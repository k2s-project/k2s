// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package lifecycle

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestPackage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "lifecycle Unit Tests", Label("unit", "ci", "lifecycle"))
}
