// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

import (
	"reflect"
	"strings"

	k8sresource "k8s.io/apimachinery/pkg/api/resource"
)

func kubeletStringMap(value any) (map[string]any, bool) {
	result := make(map[string]any)

	switch values := value.(type) {
	case map[string]any:
		for key, item := range values {
			result[strings.ToLower(key)] = item
		}
	case map[any]any:
		for key, item := range values {
			name, ok := key.(string)
			if !ok {
				return nil, false
			}
			result[strings.ToLower(name)] = item
		}
	default:
		return nil, false
	}

	return result, true
}

func kubeletInteger(value any) (int64, bool) {
	reflected := reflect.ValueOf(value)
	if !reflected.IsValid() {
		return 0, false
	}

	switch reflected.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return reflected.Int(), true
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		unsigned := reflected.Uint()
		if unsigned > uint64(^uint64(0)>>1) {
			return 0, false
		}
		return int64(unsigned), true
	default:
		return 0, false
	}
}

func validateKubeletResourceValue(path string, value any) error {
	quantity, ok := value.(string)
	if !ok || strings.TrimSpace(quantity) == "" {
		return invalidKubeletResourceValue(path)
	}

	parsed, err := k8sresource.ParseQuantity(quantity)
	if err != nil || parsed.Sign() < 0 {
		return invalidKubeletResourceValue(path)
	}

	return nil
}

func invalidKubeletResourceValue(path string) error {
	return &kubeletResourceValidationError{path: path}
}

type kubeletResourceValidationError struct {
	path string
}

func (e *kubeletResourceValidationError) Error() string {
	return "error in user-provided config: " + e.path + " must be a non-negative Kubernetes resource quantity string"
}
