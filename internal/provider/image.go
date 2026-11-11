// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package provider

// ImageProvider abstracts container image operations.
// On Windows: delegates to PowerShell scripts via SSH to VMs.
// On Linux: uses crictl/nerdctl locally + SSH to Windows VM.
type ImageProvider interface {
	// List returns the container images available in the cluster.
	List(config ImageListConfig) (*ImageListResult, error)

	// Pull pulls a container image onto a cluster node.
	Pull(config ImagePullConfig) error

	// Remove removes a container image from the cluster.
	Remove(config ImageRemoveConfig) error

	// Build builds a container image from a build context.
	Build(config ImageBuildConfig) error

	// Import imports a container image from a tar archive.
	Import(config ImageImportConfig) error

	// Export exports a container image to a tar archive.
	Export(config ImageExportConfig) error

	// Tag tags a container image with a new name.
	Tag(config ImageTagConfig) error

	// Push pushes a container image to a registry.
	Push(config ImagePushConfig) error

	// Clean removes all non-K8s container images from the cluster.
	Clean(config ImageCleanConfig) error

	// Repair re-imports missing system images from the local archives.
	Repair(config ImageRepairConfig) error

	// RegistryAdd configures access to a container registry.
	RegistryAdd(config ImageRegistryAddConfig) error

	// RegistryRemove removes access to a container registry.
	RegistryRemove(config ImageRegistryRemoveConfig) error
}

// ImageListConfig holds parameters for listing container images.
type ImageListConfig struct {
	IncludeK8sImages bool
	Nodes            string
	ShowOutput       bool
}

// ImageListResult holds the result of listing container images.
type ImageListResult struct {
	ContainerImages   []ContainerImage
	ContainerRegistry string
	PushedImages      []PushedImage
}

// ContainerImage represents a single container image.
type ContainerImage struct {
	ImageId    string
	Repository string
	Tag        string
	Node       string
	Size       string
}

// PushedImage represents an image pushed to a registry.
type PushedImage struct {
	Name string
	Tag  string
	Node string
}

// ImagePullConfig holds parameters for pulling a container image.
type ImagePullConfig struct {
	ImageName  string
	Windows    bool
	Nodes      string
	ShowOutput bool
}

// ImageRemoveConfig holds parameters for removing a container image.
type ImageRemoveConfig struct {
	ImageId      string
	ImageName    string
	Nodes        string
	FromRegistry bool
	Force        bool
	ShowOutput   bool
}

// ImageBuildConfig holds parameters for building a container image.
type ImageBuildConfig struct {
	InputFolder string
	Dockerfile  string
	ImageName   string
	ImageTag    string
	Push        bool
	Windows     bool
	BuildArgs   map[string]string
	ShowOutput  bool
}

// ImageImportConfig holds parameters for importing a container image.
type ImageImportConfig struct {
	TarPath       string
	DirPath       string
	Windows       bool
	Nodes         string
	DockerArchive bool
	ShowOutput    bool
}

// ImageExportConfig holds parameters for exporting a container image.
type ImageExportConfig struct {
	ImageId       string
	ImageName     string
	Nodes         string
	OutputPath    string
	DockerArchive bool
	ShowOutput    bool
}

// ImageTagConfig holds parameters for tagging a container image.
type ImageTagConfig struct {
	ImageId         string
	ImageName       string
	Nodes           string
	TargetImageName string
	ShowOutput      bool
}

// ImagePushConfig holds parameters for pushing a container image.
type ImagePushConfig struct {
	ImageId    string
	ImageName  string
	Nodes      string
	ShowOutput bool
}

// ImageCleanConfig holds parameters for cleaning container images.
type ImageCleanConfig struct {
	Nodes      string
	ShowOutput bool
}

// ImageRepairConfig holds parameters for repairing system container images.
type ImageRepairConfig struct {
	ShowOutput bool
}

// ImageRegistryAddConfig holds parameters for adding access to a container registry.
type ImageRegistryAddConfig struct {
	RegistryName string
	Username     string
	Password     string
	SkipVerify   bool
	PlainHttp    bool
	Nodes        string
	ShowOutput   bool
}

// ImageRegistryRemoveConfig holds parameters for removing access to a container registry.
type ImageRegistryRemoveConfig struct {
	RegistryName string
	Nodes        string
	ShowOutput   bool
}
