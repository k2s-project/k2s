// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestProvider(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "provider Unit Tests", Label("unit", "ci", "provider"))
}
