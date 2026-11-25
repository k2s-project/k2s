// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package poller

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestPollerUnitTests(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Poller Unit Tests", Label("unit", "ci"))
}
