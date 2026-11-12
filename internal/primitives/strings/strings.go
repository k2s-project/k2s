// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package strings

import (
	"fmt"
	"math"
	"time"
)

func ToStrings(items ...any) []string {
	var result []string

	for _, item := range items {
		value := ToString(item)

		result = append(result, value)
	}

	return result
}

func ToString(item any) string {
	value, ok := item.(string)

	if !ok {
		value = fmt.Sprint(item)
	}

	return value
}

func ToAgeString(duration time.Duration) string {
	hours := duration.Hours()
	if hours > 23 {
		days := math.Floor(hours / 24)
		restHours := math.Floor(hours - (days * 24))

		return fmt.Sprintf("%vd%vh", days, restHours)
	}

	return duration.Round(time.Second).String()
}
