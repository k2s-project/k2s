// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

// Package setuporchestration defines the platform-abstraction interfaces for
// cluster lifecycle operations. Each host OS (Windows, Linux) provides its own
// implementation.
//
// On Windows the orchestration delegates to PowerShell scripts (existing behavior).
// Native Linux lifecycle operations delegate from the Linux provider to Bash
// modules under lib/modules/linux. This package retains libvirt support.
package setuporchestration
