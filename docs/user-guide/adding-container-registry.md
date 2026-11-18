<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Adding a Container Registry
This page describes how to add a container registry for pulling and pushing container images.

## Registry Options of the *k2s* CLI
The *k2s* CLI provides an option to add a registry. You can find the help for registry options with following command:

```console
k2s image registry -h
```

## Adding a Registry
In the following example you can see how to add a registry:

```console
k2s image registry add shsk2s.azurecr.io
```

You will be asked for username and password. Container runtimes on *Windows* and *Linux* node will be automatically configured to get access to the added registry. Credentials are stored so that you can switch easily between configured registries.

## Listing Configured Registries
The following command shows how to display all configured registries:

```console
k2s image registry ls
```