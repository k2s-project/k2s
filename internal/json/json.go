// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package json

import (
	j "encoding/json"
	"fmt"
	"io/fs"
	"os"
)

func MarshalIndent(data any) ([]byte, error) {
	return j.MarshalIndent(data, "", "  ")
}

func FromFile[T any](path string) (v *T, err error) {
	binaries, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("could not read file '%s': %w", path, err)
	}

	err = j.Unmarshal(binaries, &v)
	if err != nil {
		return nil, fmt.Errorf("could not unmarshall file '%s' to json: %w", path, err)
	}
	return v, nil
}

func ToFile[T any](path string, v *T) (err error) {
	binaries, err := j.Marshal(v)
	if err != nil {
		return fmt.Errorf("could not marshal json to file '%s': %w", path, err)
	}

	return os.WriteFile(path, binaries, fs.ModePerm)
}
