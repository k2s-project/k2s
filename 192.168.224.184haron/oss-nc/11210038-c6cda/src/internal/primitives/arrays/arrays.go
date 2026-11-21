// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package arrays

func Insert[T any](array []T, item T, index int) []T {
	return append(array[:index], append([]T{item}, array[index:]...)...)
}
