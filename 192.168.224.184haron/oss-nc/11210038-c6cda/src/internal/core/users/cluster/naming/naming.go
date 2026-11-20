// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package naming

func DetermineK8sContext(userName, clusterName string) string {
	return userName + "@" + clusterName
}
