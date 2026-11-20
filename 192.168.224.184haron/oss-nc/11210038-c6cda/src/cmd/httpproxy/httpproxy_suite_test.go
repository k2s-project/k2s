// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestHttpproxyUnitTests(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "httpproxy Unit Tests", Label("unit", "ci"))
}
