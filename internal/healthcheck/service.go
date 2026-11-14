// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package healthcheck

import "fmt"

// HyperVServiceName is the name of the Hyper-V Virtual Machine Management service.
const HyperVServiceName = "vmms"

// ServiceRunningFunc returns whether the service with the given name is running.
type ServiceRunningFunc func(name string) (bool, error)

// NewHyperVServiceCheck returns a check that verifies that the Hyper-V Virtual Machine
// Management service, which runs the K2s VMs, is running.
func NewHyperVServiceCheck(serviceRunningFunc ServiceRunningFunc) Check {
	return Check{
		Name:        "hyperv-vmms",
		Description: "Hyper-V Virtual Machine Management service is running",
		Run: func() Outcome {
			running, err := serviceRunningFunc(HyperVServiceName)
			if err != nil {
				return fail(fmt.Sprintf("could not query service '%s': %v", HyperVServiceName, err),
					"Make sure Hyper-V is enabled on this host")
			}
			if !running {
				return fail(fmt.Sprintf("service '%s' is not running", HyperVServiceName),
					fmt.Sprintf("Start the service with 'Start-Service %s' and check the Hyper-V event logs if it stops again", HyperVServiceName))
			}
			return pass(fmt.Sprintf("service '%s' is running", HyperVServiceName))
		},
	}
}
