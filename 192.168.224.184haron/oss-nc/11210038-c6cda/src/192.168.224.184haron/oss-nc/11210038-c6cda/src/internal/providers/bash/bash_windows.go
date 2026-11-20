// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package bash

import "errors"

func platformGuard() error {
	return errors.New("this operation requires a Linux host and is not available on Windows hosts")
}
