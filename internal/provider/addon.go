// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier:   MIT

package provider

// AddonProvider abstracts addon management operations.
// On Windows: delegates to PowerShell scripts (Enable.ps1, Disable.ps1, etc.).
// On Linux: reads addon.manifest.yaml and applies manifests via kubectl directly.
type AddonProvider interface {
	// Enable enables an addon with the given parameters.
	Enable(config AddonEnableConfig) error

	// Disable disables an addon.
	Disable(config AddonDisableConfig) error

	// List returns all available addons and their status.
	List(config AddonListConfig) (*AddonListResult, error)

	// Status returns the status of specific or all addons.
	Status(config AddonStatusConfig) (*AddonStatusResult, error)

	// Export exports addon state for offline transfer.
	Export(config AddonExportConfig) error

	// Import imports addon state from an offline package.
	Import(config AddonImportConfig) error

	// RunCommand executes an arbitrary addon command (e.g., enable, disable,
	// update) as defined in the addon.manifest.yaml. The generic addon command
	// handler uses this to dispatch manifest-defined operations through the
	// provider instead of calling PowerShell directly.
	RunCommand(config AddonRunCommandConfig) error
}

// AddonEnableConfig holds parameters for enabling an addon.
type AddonEnableConfig struct {
	Name           string
	Implementation string
	Params         map[string]string // Dynamic parameters from addon.manifest.yaml flags
	ShowOutput     bool
}

// AddonDisableConfig holds parameters for disabling an addon.
type AddonDisableConfig struct {
	Name           string
	Implementation string
	Params         map[string]string
	ShowOutput     bool
}

// AddonListConfig holds parameters for listing addons.
type AddonListConfig struct {
	ShowOutput bool
}

// AddonListResult holds the list of available addons.
type AddonListResult struct {
	Addons []AddonInfo
}

// AddonInfo holds information about a single addon.
type AddonInfo struct {
	Name            string
	Enabled         bool
	Description     string
	Implementations []string
}

// AddonStatusConfig holds parameters for querying addon status.
type AddonStatusConfig struct {
	Name       string // Empty means all addons
	Directory  string // Full path to addon directory (required by PS Get-Status.ps1)
	ShowOutput bool
}

// AddonStatusResult holds addon status information.
type AddonStatusResult struct {
	Addons []AddonStatusInfo
}

// AddonStatusInfo holds status for a single addon.
type AddonStatusInfo struct {
	Name    string
	Enabled bool
	Props   []AddonStatusProp
}

// AddonStatusProp holds a single status property for an addon.
type AddonStatusProp struct {
	Name    string
	Value   any     // native type from PS (bool, string, float64, etc.)
	Okay    *bool   // nil = informational (cyan), non-nil = success/warning
	Message *string // optional display message (overrides Name: Value formatting)
}

// AddonExportConfig holds parameters for exporting addon state.
type AddonExportConfig struct {
	OutputDir  string
	Name       string // Empty means all enabled addons
	ShowOutput bool
}

// AddonImportConfig holds parameters for importing addon state.
type AddonImportConfig struct {
	InputDir   string
	Name       string // Empty means all
	ShowOutput bool
}

// AddonRunCommandConfig holds parameters for executing an arbitrary addon
// command as defined in the addon.manifest.yaml. The Params slice carries
// pre-formatted script parameters (PowerShell-style) which the Windows provider
// passes through to PS, and the Linux provider ignores for native operations.
type AddonRunCommandConfig struct {
	AddonName       string            // Addon metadata name (e.g., "dashboard")
	Implementation  string            // Selected implementation for multi-implementation addons
	CommandName     string            // Command name from manifest (e.g., "enable", "disable", "update")
	AddonDirectory  string            // Full path to addon directory
	ScriptSubPath   string            // Script path relative to addon directory (e.g., "Enable.ps1")
	Params          []string          // Pre-formatted script parameters for Windows
	ParameterValues map[string]string // Raw mapped values for native provider operations
	ShowOutput      bool
}
