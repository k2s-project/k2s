// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0
package reflection

import (
	"reflect"
	"runtime"
	"strings"
)

func GetFunctionName(function any) string {
	fullPath := runtime.FuncForPC(reflect.ValueOf(function).Pointer()).Name()
	pathParts := strings.Split(fullPath, ".")
	name := pathParts[len(pathParts)-1]
	nameParts := strings.Split(name, "-")

	return nameParts[0]
}
