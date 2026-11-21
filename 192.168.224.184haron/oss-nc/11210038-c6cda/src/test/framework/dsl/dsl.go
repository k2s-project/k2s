// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package dsl

import (
	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
)

type K2s struct {
	suite *framework.K2sTestSuite
}

type K2sCmdResult struct {
	output   string
	exitCode cli.ExitCode
}

func NewK2s(suite *framework.K2sTestSuite) *K2s {
	return &K2s{
		suite: suite,
	}
}
