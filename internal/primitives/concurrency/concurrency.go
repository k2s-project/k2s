// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package concurrency

import (
	"errors"
	"sync"
)

// RunAll runs functions concurrently and returns the joined error of all failures.
func RunAll(funcs ...func() error) error {
	errs := make([]error, len(funcs))
	var tasks sync.WaitGroup
	tasks.Add(len(funcs))

	for i, fn := range funcs {
		go func(i int, fn func() error) {
			defer tasks.Done()
			errs[i] = fn()
		}(i, fn)
	}

	tasks.Wait()

	return errors.Join(errs...)
}
