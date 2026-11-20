// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package regex

import "regexp"

const (
	IpAddressRegex = `((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}`
	VersionRegex   = `v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)`
)

var ansiEscapeRegex = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func StripAnsi(s string) string {
	return ansiEscapeRegex.ReplaceAllString(s, "")
}
