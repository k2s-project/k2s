<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

- [*K2s Testing Framework*](#k2s-testing-framework)
	- [Creating a new Test Suite](#creating-a-new-test-suite)
	- [Writing Test Specs](#writing-test-specs)
	- [Test Suite APIs](#test-suite-apis)


# *K2s Testing Framework*
To avoid writing redundant *K2s* interop code for testing purpose, *K2s* provides a testing framework.

Since this framework uses [*Ginkgo*](https://onsi.github.io/ginkgo/#top) under the hood (see also [Tech Stack](../README.md#tech-stack)), the tests/specs are organized in test suites.

Each test suite contains logically or technically cohesive test specifications that share the same prerequisites (e.g. one suite for testing a single *k2s* CLI command like `k2s status` with all available options/flags).

<span style="color:orange;font-size:medium">**⚠** </span> **All acceptance tests require a *K2s* cluster to be running** on the same machine where the tests are executed.

<span style="color:orange;font-size:medium">**⚠** </span> **All *addon*-related acceptance tests require all addons to be disabled** on the *K2s* cluster

## Creating a new Test Suite
Either use the *Ginkgo* CLI for [Bootstrapping a Suite](https://onsi.github.io/ginkgo/#bootstrapping-a-suite) or create a test suite file manually. The result should look like the following:

```go
package my_test_package

import (
  . "github.com/onsi/ginkgo/v2"
  . "github.com/onsi/gomega"
  "testing"
)

func TestMyPackage(t *testing.T) {
  RegisterFailHandler(Fail)
  RunSpecs(t, "My First Test Suite")
}
```
This 'glue' code ties the [*Go* testing package](https://pkg.go.dev/testing) and [*Ginkgo*](https://onsi.github.io/ginkgo/#top)/[*Gomega*](https://onsi.github.io/gomega/#top) together.

To make use of the *framework*, obtain a *K2sTestSuite* instance in the *BeforeSuite* hook and dispose it in the *AfterSuite* hook:

```go
package my_test_package

import (
	"context"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/test/framework"
)

// ..
var suite *framework.K2sTestSuite
// ..

func TestMyPackage(t *testing.T) {
  RegisterFailHandler(Fail)
  RunSpecs(t, "My First Test Suite")
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})
```
This way, the test suite functionality can be used in all test steps and ensures certain prerequisites like a running *K2s* cluster and proper disposal of resources. Passing the test context to the *Setup/TearDown* methods enables *Ginkgo* to automatically cancel long-running or hang tasks that exceeded certain timeouts.

## Writing Test Specs
Even though test specs can be organized in a way that the test suite definition and the specs are located in different *Go* files, it is recommend for the acceptance tests to combine test suite definition and test specs in one *Go* file:

```go
// ..
var _ = Describe("status command", func() {
	When("system is not running", Ordered, func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "stop")
		})

		Context("default output", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "status")
			})

			It("prints a header", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
			})

			It("prints setup", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().SetupConfig.SetupName))
			})
			// ..
		})

        // ..
    })
    //..
})
// ..
```
- *Describe* is the root node of the test suite (on the same level as the *BeforeSuite*/*AfterSuite* hooks)
- *When* is a context node, synonym to *Context*
- *BeforeAll* is a setup hook that runs once before all following spec nodes (i.e. *It* nodes). Only valid in combination with the *Ordered* flag to guarantee ordered spec execution. Alternatively, *BeforeEach* runs before each spec node and does not require an ordered execution, but in this case it makes sense to run the *status* command once and analyze the output in different specs covering different aspects.
- Note how the test suite instance is used to run *k2s* CLI commands without having to know where the *exe* file is located or what the file name is, e.g. `suite.K2sCli().Run(ctx, "stop")`
- *It* are the actual test specs and contain mostly assertion logic, ideally formulated using the powerful *Gomega* syntax
- Note how the test suite instance provides *K2s* setup information via `suite.SetupInfo().SetupType.Name`

## Test Suite APIs
E.g. `suite.K2sCli()`:
| API                                        | Description                                                                                                                                                                                                                                                      |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Setup(ctx context.Context, args ...any)    | initializes all APIs based on the current *K2s* cluster installation; params:<br>- ctx: test context for execution control<br>-args: set of optional parameters, e.g. `EnsureAddonsAreDisabled` or `ClusterTestStepTimeout(3*time.Second)`                       |
| TearDown(ctx context.Context, args ...any) | disposes all resources claimed during test execution; params:<br>- ctx: test context for execution control<br>-args: set of optional parameters, e.g. `RestartKubeProxy`                                                                                         |
| TestStepTimeout()                          | how long to wait for the test step to complete; can be either set through environment variables (see [env.go](env.go)) or as *Setup*/*TearDown* parameter. If no value is provided, the default will be used.                                                    |
| TestStepPollInterval()                     | how long to wait before polling for the expected result check within the timeout period; can be either set through environment variables (see [env.go](env.go)) or as *Setup*/*TearDown* parameter. If no value is provided, the default will be used.           |
| Proxy()                                    | the http(s) proxy to use; can be set through environment variables (see [env.go](env.go)). Default is empty.                                                                                                                                                     |  |
| Cli()                                      | OS CLI wrapper for running arbitrary commands                                                                                                                                                                                                                    |  |
| K2sCli()                                   | convenience wrapper around k2s.exe; provides 'syntactic sugar'                                                                                                                                                                                                   |  |
| Kubectl()                                  | convenience wrapper around the *kubectl* CLI                                                                                                                                                                                                                     |  |
| SetupInfo()                                | provides config data for the *K2s* installation, e.g. setup type or name of the control-plane VM                                                                                                                                                                 |  |
| Cluster()                                  | API to interact with the *K8s* cluster; provides assertions based on the official [Kubernetes E2E Framework](https://github.com/kubernetes-sigs/e2e-framework#e2e-framework), e.g. waiting for certain Pods to be in ready state within a certain amount of time |

For the respective APIs in the sub-packages, please refer to the [*framework* folder](./).
