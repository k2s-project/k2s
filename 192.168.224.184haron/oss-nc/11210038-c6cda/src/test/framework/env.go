// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package framework

import (
	"os"
	"strconv"
	"time"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

const (
	defaultTestStepTimeout      = 5 * time.Minute
	defaultTestStepPollInterval = 1 * time.Second
)

func determineProxy() string {
	proxy := os.Getenv("SYSTEM_TEST_PROXY")

	if proxy != "" {
		GinkgoWriter.Println("Proxy set to <", proxy, ">")
	}

	return proxy
}

func determineOfflineMode() bool {
	value, ok := os.LookupEnv("SYSTEM_OFFLINE_MODE")
	if ok {

		boolValue, err := strconv.ParseBool(value)
		if err != nil {
			GinkgoWriter.Println("Error parsing boolean environment variable: %v\n", err)
		}

		if boolValue {
			GinkgoWriter.Println("Set to System Offline Mode")
		}
		return boolValue
	}

	return false
}

func determineKeepResourcesOnError() bool {
	value, ok := os.LookupEnv("SYSTEM_TEST_KEEP_RESOURCES_ON_ERROR")
	if ok {
		boolValue, err := strconv.ParseBool(value)
		if err != nil {
			GinkgoWriter.Println("Error parsing boolean environment variable: %v\n", err)
		}

		if boolValue {
			GinkgoWriter.Println("Set to keep resources on error")
		}
		return boolValue
	}

	return false
}

func determineTestStepTimeout() time.Duration {
	return determineDurationFromEnv("SYSTEM_TEST_TIMEOUT", "Timeout", defaultTestStepTimeout)
}

func determineTestStepPollInterval() time.Duration {
	return determineDurationFromEnv("SYSTEM_TEST_POLL_INTERVAL", "Poll interval", defaultTestStepPollInterval)
}

func determineDurationFromEnv(key string, displayName string, defaultValue time.Duration) time.Duration {
	envValue := os.Getenv(key)

	if envValue != "" {
		GinkgoWriter.Println(displayName, "set to <", envValue, ">")

		value, err := time.ParseDuration(envValue)

		Expect(err).ToNot(HaveOccurred())

		return value
	}

	return defaultValue
}
