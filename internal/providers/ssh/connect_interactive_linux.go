// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package ssh

func ConnectInteractively(options ConnectionOptions) error {
	return connectInteractively(options, "ssh")
}
