// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package output

type StreamWriter interface {
	WriteStdOut(message string)
	WriteStdErr(message string)
	Flush()
}
