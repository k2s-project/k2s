<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Tags/Labels
To control which tests or test types shall be executed in which context/environment, tags/labels can be utilized.

!!! note
    **Tags** and **labels** can be used synonymously.<br/>
    See [*Pester* Tag Documentation](https://pester.dev/docs/usage/tags){target="_blank"} for information about tagging/labelling Pester tests.<br/>
    See [*Ginkgo* Spec Labels Documentation](https://onsi.github.io/ginkgo/#spec-labels){target="_blank"} for information about tagging/labelling Ginkgo tests.

## *Pester* Example
Define one or more tags at any level of a test container:
```PowerShell
# ...
Describe 'Get-Status' -Tag 'unit', 'addon' {
    # ...
}
# ...
```
Execute tests with tag *unit*:
```PowerShell
Invoke-Pester <dir-with-test-files> -Tag unit
```

## *Ginkgo* Example
Define one or more labels at any level of a test node, here for a whole test suite:
```Go
// ...
func TestHttpproxyUnitTests(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "httpproxy Unit Tests", Label("unit", "ci"))
}
// ...
```
Execute tests with tag *unit*:
```console
ginkgo --label-filter="unit" <dir-with-test-suites>
```

## Commonly Used Tags
| Name                     | Description                                                                                                                |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| **acceptance**           | end-to-end test/executable spec in production-like scenario                                                                |
| **integration**          | test requiring certain external resources/systems to be reachable or additional software to be installed                   |
| **unit**                 | test can be executed in isolation, all dependencies to the environment are mocked                                          |
| **ci**                   | test that is fast-running and therefore applicable to CI runs; applies most likely to all unit tests                       |
| **addon**                | test is addon-related and does not test *K2s* core functionality                                                           |
| **internet-required**    | test requires internet connectivity, e.g. for package downloads                                                            |
| **invasive**             | test changes either state of the host system or *K2s* installation                                                         |
| **read-only**            | test does not change state of the host system or *K2s* installation; optional, since read-only tests should be the default |
| **setup-required**       | test requires *K2s* to be installed; currently, the tests determine the setup type in the test runs                        |
| **no-setup**             | *K2s* must not be installed on the system to test pre-installation behavior                                                |
| **setup=\<setup name\>** | *K2s* setup type must match, e.g. *setup=k2s*                                                                              |
| **system-running**       | test requires *K2s* to be started/running                                                                                  |
| **system-stopped**       | test requires *K2s* to be stopped                                                                                          |