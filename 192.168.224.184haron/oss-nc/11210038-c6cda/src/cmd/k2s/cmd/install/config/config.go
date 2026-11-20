// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

import (
	"bytes"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"embed"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/spf13/pflag"
	"github.com/spf13/viper"
)

type Kind string

type installConfigAccess struct {
	config             *viper.Viper
	embeddedFileReader fileReader
	osFileReader       fileReader
	validator          configValidator
	converter          configConverter
	overwriter         configOverwriter
}

type embeddedFileReader struct{}

type osFileReader struct{}

type userConfigValidator struct{}

type viperConfigConverter struct{}

type cliParamsConfigOverwriter struct{}

type fileReader interface {
	readFile(path string) ([]byte, error)
}

type configValidator interface {
	validate(kind Kind, config *viper.Viper) error
}

type configConverter interface {
	convert(config *viper.Viper) (*InstallConfig, error)
}

type configOverwriter interface {
	overwrite(iConfig *InstallConfig, vConfig *viper.Viper, flags *pflag.FlagSet)
}

type InstallConfig struct {
	Kind             string                 `mapstructure:"kind" json:"kind" yaml:"kind"`
	ApiVersion       string                 `mapstructure:"apiVersion" json:"apiVersion" yaml:"apiVersion"`
	Nodes            []NodeConfig           `mapstructure:"nodes" json:"nodes" yaml:"nodes"`
	Env              EnvConfig              `mapstructure:"env" json:"env" yaml:"env"`
	Behavior         BehaviorConfig         `mapstructure:"installBehavior" json:"installBehavior" yaml:"installBehavior"`
	LinuxOnly        bool                   `mapstructure:"linuxOnly" json:"linuxOnly" yaml:"linuxOnly"`
	WindowsQCOW2Path string                 `mapstructure:"windowsQCOW2Path" json:"windowsQCOW2Path" yaml:"windowsQCOW2Path"`
	KubeletOverrides KubeletOverridesConfig `mapstructure:"kubeletOverrides" json:"kubeletOverrides" yaml:"kubeletOverrides"`
}

type KubeletOverridesConfig struct {
	LinuxControlPlane *KubeletRoleConfig `mapstructure:"linuxControlPlane" json:"linuxControlPlane,omitempty" yaml:"linuxControlPlane,omitempty"`
	WindowsWorker     *KubeletRoleConfig `mapstructure:"windowsWorker" json:"windowsWorker,omitempty" yaml:"windowsWorker,omitempty"`
}

type KubeletRoleConfig struct {
	Enabled bool                          `mapstructure:"enabled" json:"enabled" yaml:"enabled"`
	Config  KubeletConfigurationOverrides `mapstructure:"config" json:"config" yaml:"config"`
}

type KubeletConfigurationOverrides struct {
	MaxPods        *int64            `mapstructure:"maxPods" json:"maxPods,omitempty" yaml:"maxPods,omitempty"`
	SystemReserved ResourceOverrides `mapstructure:"systemReserved" json:"systemReserved,omitempty" yaml:"systemReserved,omitempty"`
	KubeReserved   ResourceOverrides `mapstructure:"kubeReserved" json:"kubeReserved,omitempty" yaml:"kubeReserved,omitempty"`
}

type ResourceOverrides struct {
	Cpu    string `mapstructure:"cpu" json:"cpu,omitempty" yaml:"cpu,omitempty"`
	Memory string `mapstructure:"memory" json:"memory,omitempty" yaml:"memory,omitempty"`
}

type NodeConfig struct {
	Role      string         `mapstructure:"role"`
	Resources ResourceConfig `mapstructure:"resources"`
}

type ResourceConfig struct {
	Cpu           string `mapstructure:"cpu"`
	Memory        string `mapstructure:"memory"`
	MemoryMin     string `mapstructure:"memoryMin"`
	MemoryMax     string `mapstructure:"memoryMax"`
	DynamicMemory bool   `mapstructure:"dynamicMemory"`
	Disk          string `mapstructure:"disk"`
}

type EnvConfig struct {
	Proxy              string   `mapstructure:"httpProxy" json:"httpProxy" yaml:"httpProxy"`
	NoProxy            []string `mapstructure:"noProxy" json:"noProxy" yaml:"noProxy"`
	AdditionalHooksDir string   `mapstructure:"additionalHooksDir" json:"additionalHooksDir" yaml:"additionalHooksDir"`
	RestartPostInstall string   `mapstructure:"restartPostInstallCount" json:"restartPostInstallCount" yaml:"restartPostInstallCount"`
	K8sBins            string   `mapstructure:"k8sBins" json:"k8sBins" yaml:"k8sBins"`
}

type BehaviorConfig struct {
	ShowOutput                        bool `mapstructure:"showOutput"`
	DeleteFilesForOfflineInstallation bool `mapstructure:"deleteFilesForOfflineInstallation"`
	ForceOnlineInstallation           bool `mapstructure:"forceOnlineInstallation"`
	Wsl                               bool `mapstructure:"wsl"`
	AppendLog                         bool `mapstructure:"appendLog"`
	SkipStart                         bool `mapstructure:"skipStart"`
}

const (
	k2sConfigType       Kind = "k2s"
	BuildonlyConfigType Kind = "buildonly"

	SupportedApiVersion  = "v1"
	ControlPlaneRoleName = "control-plane"
	WorkerRoleName       = "worker"

	ControlPlaneCPUsFlagName  = "master-cpus"
	ControlPlaneCPUsFlagUsage = "Number of CPUs allocated to master VM"

	ControlPlaneMemoryFlagName  = "master-memory"
	ControlPlaneMemoryFlagUsage = "Amount of RAM to allocate to master VM (minimum 2GB, format: <number>[<unit>], where unit = KB, MB or GB)"

	ControlPlaneMemoryMinFlagName  = "master-memory-min"
	ControlPlaneMemoryMinFlagUsage = "Minimum amount of RAM for dynamic memory (format: <number>[<unit>], where unit = KB, MB or GB)"

	ControlPlaneMemoryMaxFlagName  = "master-memory-max"
	ControlPlaneMemoryMaxFlagUsage = "Maximum amount of RAM for dynamic memory (format: <number>[<unit>], where unit = KB, MB or GB)"

	ControlPlaneDiskSizeFlagName  = "master-disk"
	ControlPlaneDiskSizeFlagUsage = "Disk size allocated to the master VM (minimum 10GB, format: <number>[<unit>], where unit = KB, MB or GB)"

	WorkerCPUsFlagName  = "worker-cpus"
	WorkerCPUsFlagUsage = "Number of CPUs allocated to the managed Windows worker VM"

	WorkerMemoryFlagName  = "worker-memory"
	WorkerMemoryFlagUsage = "Amount of RAM to allocate to the managed Windows worker VM (minimum 2GB, format: <number>GB)"

	WorkerDiskSizeFlagName  = "worker-disk"
	WorkerDiskSizeFlagUsage = "Disk size allocated to the managed Windows worker VM (minimum 20GB, format: <number>GB)"

	WindowsQCOW2PathFlagName  = "windows-qcow2-path"
	WindowsQCOW2PathFlagUsage = "Path to a prepared Windows QCOW2 image for the managed Windows worker VM"

	ProxyFlagName      = "proxy"
	ProxyFlagShorthand = "p"
	ProxyFlagUsage     = "HTTP Proxy"

	NoProxyFlagName  = "no-proxy"
	NoProxyFlagUsage = "No proxy hosts/domains (comma-separated list)"

	ConfigFileFlagName      = "config"
	ConfigFileFlagShorthand = "c"
	ConfigFileFlagUsage     = "Path to config file to load. This configuration overwrites other CLI parameters"

	WslFlagName  = "wsl"
	WslFlagUsage = "Use WSL2 for hosting of KubeMaster"

	K8sBinFlagName  = "k8s-bins"
	K8sBinFlagUsage = "Path to directory of locally built Kubernetes binaries (kubelet.exe, kube-proxy.exe, kubeadm.exe, kubectl.exe)"

	LinuxOnlyFlagName  = "linux-only"
	LinuxOnlyFlagUsage = "No Windows worker node will be set up"

	AppendLogFlagName  = "append-log"
	AppendLogFlagUsage = "Append logs to existing log file"

	SkipStartFlagName  = "skip-start"
	SkipStartFlagUsage = "Do not start the K8s cluster automatically after installation"

	RestartFlagUsage = "Number of times to restart cluster post installation."

	minMemoryBytes int64 = 2 * 1024 * 1024 * 1024
	maxMemoryBytes int64 = 128 * 1024 * 1024 * 1024
)

var (
	//go:embed embed/*.config.yaml
	embeddedConfigFiles embed.FS

	configFileMap map[Kind]string = map[Kind]string{
		k2sConfigType:       "k2s.config.yaml",
		BuildonlyConfigType: "buildonly.config.yaml"}
)

func NewInstallConfigAccess() *installConfigAccess {
	return &installConfigAccess{
		config:             viper.New(),
		embeddedFileReader: &embeddedFileReader{},
		osFileReader:       &osFileReader{},
		validator:          &userConfigValidator{},
		converter:          &viperConfigConverter{},
		overwriter:         &cliParamsConfigOverwriter{},
	}
}

func LoadFile(path string) (*InstallConfig, error) {
	access := NewInstallConfigAccess()
	if err := access.loadBaseConfig(k2sConfigType); err != nil {
		return nil, err
	}
	access.config.Set(ConfigFileFlagName, path)
	if err := access.loadUserConfig(k2sConfigType); err != nil {
		return nil, err
	}
	return access.normalize(nil)
}

func (i *installConfigAccess) Load(kind Kind, flags *pflag.FlagSet) (*InstallConfig, error) {
	i.config.BindPFlags(flags)

	err := i.loadBaseConfig(kind)
	if err != nil {
		return nil, err
	}

	if i.config.IsSet(ConfigFileFlagName) {
		err = i.loadUserConfig(kind)
		if err != nil {
			return nil, err
		}
	}

	return i.normalize(flags)
}

func (i *installConfigAccess) normalize(flags *pflag.FlagSet) (*InstallConfig, error) {
	config, err := i.converter.convert(i.config)
	if err != nil {
		return nil, err
	}

	if flags != nil {
		i.overwriter.overwrite(config, i.config, flags)
	}

	autoEnableDynamicMemory(config)

	if err := validateResourceValues(config); err != nil {
		return nil, err
	}
	if err := validateEnvValues(config); err != nil {
		return nil, err
	}
	if err := validateDynamicMemoryConfiguration(config); err != nil {
		return nil, err
	}
	if err := validateWslCompatibility(config); err != nil {
		return nil, err
	}

	return config, nil
}

func (config *InstallConfig) GetNodeByRole(role string) (*NodeConfig, error) {
	result, found := config.findNodeByRole(role)

	if !found {
		return nil, fmt.Errorf("node config not found for role '%s'", role)
	}

	return result, nil
}

// FindNodeByRole reports whether the role is configured. Unlike GetNodeByRole it
// does not treat a missing node as an error, for roles that are optional.
func (config *InstallConfig) FindNodeByRole(role string) (*NodeConfig, bool) {
	return config.findNodeByRole(role)
}

// GetOrCreateNodeByRole returns the configured node for the role, adding an
// empty one when the config does not define it. Resource values are left blank
// on purpose: the defaults live in cfg/config.json and are resolved at the point
// of use, so they are not duplicated here.
func (config *InstallConfig) GetOrCreateNodeByRole(role string) *NodeConfig {
	if node, found := config.findNodeByRole(role); found {
		return node
	}
	config.Nodes = append(config.Nodes, NodeConfig{Role: role})
	return &config.Nodes[len(config.Nodes)-1]
}

func (i *installConfigAccess) loadBaseConfig(kind Kind) error {
	configPath := fmt.Sprintf("embed/%s", configFileMap[kind])

	slog.Debug("Loading embedded config file", "path", configPath)

	content, err := i.embeddedFileReader.readFile(configPath)
	if err != nil {
		return err
	}

	i.config.SetConfigType("yaml")

	slog.Debug("Parsing embedded config file")

	return i.config.ReadConfig(bytes.NewReader(content))
}

func (i *installConfigAccess) loadUserConfig(kind Kind) error {
	userPath := i.config.GetString(ConfigFileFlagName)

	slog.Debug("Loading user-provided config file", "path", userPath)

	userContent, err := i.osFileReader.readFile(userPath)
	if err != nil {
		return err
	}

	slog.Debug("Parsing and merging user-provided config file")

	err = i.config.ReadConfig(bytes.NewReader(userContent))
	if err != nil {
		return err
	}

	return i.validator.validate(kind, i.config)
}

func (config *InstallConfig) findNodeByRole(role string) (*NodeConfig, bool) {
	for i := range config.Nodes {
		if config.Nodes[i].Role == role {
			return &config.Nodes[i], true
		}
	}
	return nil, false
}

func (config *InstallConfig) getNodeByRolePanic(role string) *NodeConfig {
	result, found := config.findNodeByRole(role)

	if !found {
		panic(fmt.Errorf("node config not found for role '%s'", role))
	}

	return result
}

func (*userConfigValidator) validate(kind Kind, config *viper.Viper) error {
	slog.Debug("Validating user-provided config file")

	if Kind(config.GetString("kind")) != kind {
		return fmt.Errorf("error in user-provided config: expected kind '%s', but found: '%s'", kind, config.GetString("kind"))
	}

	if config.GetString("apiVersion") != SupportedApiVersion {
		return fmt.Errorf("error in user-provided config: API version mismatch. Supported: %s, found: '%s'", SupportedApiVersion, config.GetString("apiVersion"))
	}

	if err := validateKubeletOverrides(config); err != nil {
		return err
	}

	nodes := config.Get("nodes").([]any)
	for _, node := range nodes {
		n, ok := node.(map[string]any)
		if !ok {
			return fmt.Errorf("error in user-provided config: invalid node configuration")
		}

		if n["role"] != ControlPlaneRoleName && n["role"] != WorkerRoleName {
			return fmt.Errorf("error in user-provided config: Invalid node role name. Supported: (%s, %s), found: '%s'", ControlPlaneRoleName, WorkerRoleName, n["role"])
		}
	}

	return nil
}

func validateKubeletOverrides(config *viper.Viper) error {
	value := config.Get("kubeletoverrides")
	if value == nil {
		return nil
	}

	overrides, ok := kubeletStringMap(value)
	if !ok {
		return fmt.Errorf("error in user-provided config: kubeletOverrides must be an object")
	}

	for role, rawRole := range overrides {
		if role != "linuxcontrolplane" && role != "windowsworker" {
			return fmt.Errorf("error in user-provided config: unsupported kubeletOverrides role '%s'", role)
		}

		roleConfig, ok := kubeletStringMap(rawRole)
		if !ok {
			return fmt.Errorf("error in user-provided config: kubeletOverrides.%s must be an object", role)
		}
		if err := validateKubeletRole(role, roleConfig); err != nil {
			return err
		}
	}

	return nil
}

func validateKubeletRole(role string, roleConfig map[string]any) error {
	for field := range roleConfig {
		if field != "enabled" && field != "config" {
			return fmt.Errorf("error in user-provided config: unsupported kubeletOverrides.%s field '%s'", role, field)
		}
	}

	if enabled, exists := roleConfig["enabled"]; exists {
		if _, ok := enabled.(bool); !ok {
			return fmt.Errorf("error in user-provided config: kubeletOverrides.%s.enabled must be a boolean", role)
		}
	}

	rawConfig, exists := roleConfig["config"]
	if !exists || rawConfig == nil {
		return nil
	}
	configValues, ok := kubeletStringMap(rawConfig)
	if !ok {
		return fmt.Errorf("error in user-provided config: kubeletOverrides.%s.config must be an object", role)
	}

	for field, value := range configValues {
		switch field {
		case "maxpods":
			maxPods, ok := kubeletInteger(value)
			if !ok || maxPods <= 0 {
				return fmt.Errorf("error in user-provided config: kubeletOverrides.%s.config.maxPods must be a positive integer", role)
			}
		case "systemreserved", "kubereserved":
			if err := validateKubeletResources(role, field, value); err != nil {
				return err
			}
		default:
			return fmt.Errorf("error in user-provided config: unsupported kubeletOverrides.%s.config field '%s'", role, field)
		}
	}

	return nil
}

func validateKubeletResources(role string, field string, value any) error {
	resources, ok := kubeletStringMap(value)
	if !ok {
		return fmt.Errorf("error in user-provided config: kubeletOverrides.%s.config.%s must be an object", role, field)
	}

	for resource, rawValue := range resources {
		if resource != "cpu" && resource != "memory" {
			return fmt.Errorf("error in user-provided config: unsupported kubeletOverrides.%s.config.%s field '%s'", role, field, resource)
		}
		path := fmt.Sprintf("kubeletOverrides.%s.config.%s.%s", role, field, resource)
		if err := validateKubeletResourceValue(path, rawValue); err != nil {
			return err
		}
	}

	return nil
}

func (*viperConfigConverter) convert(config *viper.Viper) (*InstallConfig, error) {
	var result InstallConfig

	err := config.Unmarshal(&result)
	if err != nil {
		return nil, err
	}

	return &result, nil
}

func (*cliParamsConfigOverwriter) overwrite(iConfig *InstallConfig, vConfig *viper.Viper, flags *pflag.FlagSet) {
	slog.Debug("Overwriting config with CLI params")

	memoryExplicitlySet := false
	memoryMinSet := false
	memoryMaxSet := false

	flags.Visit(func(flag *pflag.Flag) {
		if flag.Name == ControlPlaneMemoryFlagName {
			memoryExplicitlySet = true
		}
		if flag.Name == ControlPlaneMemoryMinFlagName {
			memoryMinSet = true
		}
		if flag.Name == ControlPlaneMemoryMaxFlagName {
			memoryMaxSet = true
		}
		overwriteConfigWithCliParam(iConfig, vConfig, flag.Name)
	})

	if (memoryMinSet || memoryMaxSet) && !memoryExplicitlySet {
		node := iConfig.getNodeByRolePanic(ControlPlaneRoleName)

		if node.Resources.MemoryMin != "" {
			slog.Debug("Auto-setting startup memory to minimum (Memory flag not explicitly set)", "min", node.Resources.MemoryMin)
			node.Resources.Memory = node.Resources.MemoryMin
		} else if memoryMaxSet {
			slog.Debug("Only max memory set - auto-setting startup to 2GB (Kubernetes minimum)")
			node.Resources.Memory = "2GB"
		}
	}
}

func overwriteConfigWithCliParam(iConfig *InstallConfig, vConfig *viper.Viper, flagName string) {
	slog.Debug("Overwriting config with CLI param", "param", flagName)

	switch flagName {
	case common.AdditionalHooksDirFlagName:
		iConfig.Env.AdditionalHooksDir = vConfig.GetString(flagName)
	case common.ForceOnlineInstallFlagName:
		iConfig.Behavior.ForceOnlineInstallation = vConfig.GetBool(flagName)
	case common.DeleteFilesFlagName:
		iConfig.Behavior.DeleteFilesForOfflineInstallation = vConfig.GetBool(flagName)
	case common.OutputFlagName:
		iConfig.Behavior.ShowOutput = vConfig.GetBool(flagName)
	case AppendLogFlagName:
		iConfig.Behavior.AppendLog = vConfig.GetBool(flagName)
	case LinuxOnlyFlagName:
		iConfig.LinuxOnly = vConfig.GetBool(flagName)
	case ControlPlaneCPUsFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.Cpu = vConfig.GetString(flagName)
	case ControlPlaneDiskSizeFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.Disk = vConfig.GetString(flagName)
	case ControlPlaneMemoryFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.Memory = vConfig.GetString(flagName)
	case ControlPlaneMemoryMinFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.MemoryMin = vConfig.GetString(flagName)
	case ControlPlaneMemoryMaxFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.MemoryMax = vConfig.GetString(flagName)
	case WorkerCPUsFlagName:
		iConfig.GetOrCreateNodeByRole(WorkerRoleName).Resources.Cpu = vConfig.GetString(flagName)
	case WorkerMemoryFlagName:
		iConfig.GetOrCreateNodeByRole(WorkerRoleName).Resources.Memory = vConfig.GetString(flagName)
	case WorkerDiskSizeFlagName:
		iConfig.GetOrCreateNodeByRole(WorkerRoleName).Resources.Disk = vConfig.GetString(flagName)
	case WindowsQCOW2PathFlagName:
		iConfig.WindowsQCOW2Path = vConfig.GetString(flagName)
	case ProxyFlagName:
		iConfig.Env.Proxy = vConfig.GetString(flagName)
	case NoProxyFlagName:
		iConfig.Env.NoProxy = vConfig.GetStringSlice(flagName)
	case SkipStartFlagName:
		iConfig.Behavior.SkipStart = vConfig.GetBool(flagName)
	case WslFlagName:
		iConfig.Behavior.Wsl = vConfig.GetBool(flagName)
	case K8sBinFlagName:
		iConfig.Env.K8sBins = vConfig.GetString(flagName)
	}
}

func (*embeddedFileReader) readFile(path string) ([]byte, error) {
	return embeddedConfigFiles.ReadFile(path)
}

func (*osFileReader) readFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func autoEnableDynamicMemory(config *InstallConfig) {
	for i := range config.Nodes {
		node := &config.Nodes[i]

		if node.Resources.MemoryMin != "" || node.Resources.MemoryMax != "" {
			if !node.Resources.DynamicMemory {
				slog.Debug("Auto-enabling dynamic memory based on min/max flags", "role", node.Role)
				node.Resources.DynamicMemory = true
			}
		}
	}
}

func validateMemoryBounds(memoryBytes int64, parameterName string, parameterValue string) error {
	if memoryBytes < minMemoryBytes {
		return fmt.Errorf("memory configuration error: %s (%s) must be at least 2GB (Kubernetes requirement)", parameterName, parameterValue)
	}
	if memoryBytes > maxMemoryBytes {
		return fmt.Errorf("memory configuration error: %s (%s) exceeds maximum allowed (128GB). Please use a smaller value", parameterName, parameterValue)
	}
	return nil
}

func validateDynamicMemoryConfiguration(config *InstallConfig) error {
	for i := range config.Nodes {
		node := &config.Nodes[i]

		if !node.Resources.DynamicMemory {
			continue
		}

		if node.Resources.MemoryMin == "" && node.Resources.MemoryMax == "" {
			return fmt.Errorf("dynamic memory configuration error: when dynamic memory is enabled, at least one of --master-memory-min or --master-memory-max must be specified")
		}

		// Parse and validate memory sizes
		var minBytes, maxBytes, startupBytes int64
		var err error

		if node.Resources.MemoryMin != "" {
			minBytes, err = parseMemorySize(node.Resources.MemoryMin)
			if err != nil {
				return fmt.Errorf("invalid memory minimum value '%s': %w", node.Resources.MemoryMin, err)
			}
			if err := validateMemoryBounds(minBytes, "minimum memory", node.Resources.MemoryMin); err != nil {
				return err
			}
			slog.Debug("Parsed MemoryMin", "input", node.Resources.MemoryMin, "bytes", minBytes, "GB", float64(minBytes)/(1000*1000*1000))
		}

		if node.Resources.MemoryMax != "" {
			maxBytes, err = parseMemorySize(node.Resources.MemoryMax)
			if err != nil {
				return fmt.Errorf("invalid memory maximum value '%s': %w", node.Resources.MemoryMax, err)
			}
			if err := validateMemoryBounds(maxBytes, "maximum memory", node.Resources.MemoryMax); err != nil {
				return err
			}
			slog.Debug("Parsed MemoryMax", "input", node.Resources.MemoryMax, "bytes", maxBytes, "GB", float64(maxBytes)/(1000*1000*1000))
		}

		if node.Resources.Memory != "" {
			startupBytes, err = parseMemorySize(node.Resources.Memory)
			if err != nil {
				return fmt.Errorf("invalid memory value '%s': %w", node.Resources.Memory, err)
			}
			slog.Debug("Parsed Memory", "input", node.Resources.Memory, "bytes", startupBytes, "GB", float64(startupBytes)/(1000*1000*1000))
		}

		// Debug logging
		slog.Debug("Validation checks",
			"minBytes > maxBytes", minBytes > maxBytes,
			"minBytes > startupBytes", minBytes > startupBytes,
			"maxBytes < startupBytes", maxBytes < startupBytes)

		// Validate min <= max (only if both are specified)
		if node.Resources.MemoryMin != "" && node.Resources.MemoryMax != "" {
			if minBytes > maxBytes {
				return fmt.Errorf("dynamic memory configuration error: minimum memory (%s) cannot be greater than maximum memory (%s)",
					node.Resources.MemoryMin, node.Resources.MemoryMax)
			}
		}

		// Validate min <= startup (only if both are specified)
		if node.Resources.MemoryMin != "" && node.Resources.Memory != "" {
			if minBytes > startupBytes {
				return fmt.Errorf("dynamic memory configuration error: minimum memory (%s) cannot be greater than startup memory (%s)",
					node.Resources.MemoryMin, node.Resources.Memory)
			}
		}

		// Validate max >= startup (only if both are specified)
		if node.Resources.MemoryMax != "" && node.Resources.Memory != "" {
			if maxBytes < startupBytes {
				return fmt.Errorf("dynamic memory configuration error: maximum memory (%s) cannot be less than startup memory (%s)",
					node.Resources.MemoryMax, node.Resources.Memory)
			}
		}
	}

	return nil
}

// validateWslCompatibility validates WSL-specific configurations
func validateWslCompatibility(config *InstallConfig) error {
	// WSL + Dynamic Memory is not supported
	if config.Behavior.Wsl {
		for i := range config.Nodes {
			node := &config.Nodes[i]
			if node.Resources.DynamicMemory {
				return fmt.Errorf("dynamic memory configuration error: dynamic memory (--master-memory-min / --master-memory-max) is not supported with WSL2 (--wsl). WSL2 has its own memory management. Please remove the memory min/max flags when using --wsl")
			}
		}
	}

	return nil
}

// parseMemorySize parses memory size strings like "4GB", "8GB", etc.
func parseMemorySize(size string) (int64, error) {
	if size == "" {
		return 0, fmt.Errorf("empty memory size")
	}

	size = strings.TrimSpace(size)
	size = strings.ToUpper(size)

	suffixes := []struct {
		suffix     string
		multiplier int64
	}{
		{"TB", 1024 * 1024 * 1024 * 1024},
		{"GB", 1024 * 1024 * 1024},
		{"MB", 1024 * 1024},
		{"KB", 1024},
		{"T", 1024 * 1024 * 1024 * 1024},
		{"G", 1024 * 1024 * 1024},
		{"M", 1024 * 1024},
		{"K", 1024},
		{"B", 1},
	}

	// Try each suffix in order (longest first)
	for _, s := range suffixes {
		if strings.HasSuffix(size, s.suffix) {
			numStr := strings.TrimSuffix(size, s.suffix)
			numStr = strings.TrimSpace(numStr)

			var num float64
			_, err := fmt.Sscanf(numStr, "%f", &num)
			if err != nil {
				continue
			}

			return int64(num * float64(s.multiplier)), nil
		}
	}

	// Try parsing as plain number (bytes)
	var num int64
	_, err := fmt.Sscanf(size, "%d", &num)
	if err != nil {
		return 0, fmt.Errorf("unable to parse memory size: %s", size)
	}

	return num, nil
}
