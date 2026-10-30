// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier:   MIT

package generic

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"sort"
	"strings"

	ac "github.com/k2s-project/k2s/cmd/k2s/cmd/addons/common"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/addonplacement"
	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/pterm/pterm"
	"github.com/samber/lo"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

func NewCommands(allAddons addons.Addons) (commands []*cobra.Command, err error) {
	commandMap := map[string]*cobra.Command{}

	for _, addon := range allAddons {
		if len(addon.Spec.Implementations) == 0 || addon.Spec.Implementations[0].Commands == nil || len(*addon.Spec.Implementations[0].Commands) == 0 {
			return nil, fmt.Errorf("no cmd config found for addon '%s'", addon.Metadata.Name)
		}

		for cmdName, _ := range *addon.Spec.Implementations[0].Commands {
			if _, ok := commandMap[cmdName]; !ok {
				slog.Debug("Command not existing, creating it", "command", cmdName)

				cmd := &cobra.Command{
					Use:   cmdName,
					Short: fmt.Sprintf("Runs '%s' for the specific addon", cmdName),
				}
				commandMap[cmdName] = cmd
			}

			subCmd, err := newAddonCmd(addon, cmdName)
			if err != nil {
				return nil, err
			}

			commandMap[cmdName].AddCommand(subCmd)
		}
	}

	keys := lo.Keys(commandMap)
	sort.Strings(keys)

	lo.ForEach(keys, func(item string, _ int) {
		commands = append(commands, commandMap[item])
	})

	return
}

func newAddonCmd(addon addons.Addon, cmdName string) (*cobra.Command, error) {
	slog.Debug("Creating sub-command for addon", "command", cmdName, "addon", addon.Metadata.Name)

	cmd := &cobra.Command{
		Use:   addon.Metadata.Name,
		Short: fmt.Sprintf("Runs '%s' for '%s' addon", cmdName, addon.Metadata.Name),
		Long:  addonCommandLongDescription(addon, cmdName),
		Args:  validateAddonCommandArgs,
	}

	for _, implementation := range addon.Spec.Implementations {
		if addon.Metadata.Name != implementation.Name {
			slog.Debug("Creating sub-command for addon implementation", "command", cmdName, "addon", addon.Metadata.Name, "implementation", implementation)
			implementationCmd, err := newImplementationCmd(addon, cmdName, implementation)
			if err != nil {
				return nil, err
			}
			cmd.AddCommand(implementationCmd)
		} else {
			cmd.RunE = func(cmd *cobra.Command, args []string) error {
				return runCmd(cmd, addon, cmdName, implementation, args)
			}

			cmdConfig := (*implementation.Commands)[cmdName]
			if cmdConfig.Cli != nil {
				cmd.Example = cmdConfig.Cli.Examples.String()

				for _, flag := range cmdConfig.Cli.Flags {
					if err := addFlag(flag, cmd.Flags()); err != nil {
						return nil, err
					}
				}
			}

			cmd.Flags().SortFlags = false
			cmd.Flags().PrintDefaults()
		}
	}

	if cmd.RunE == nil {
		if defaultImplementation, found := ac.FindDefaultImplementationForAddon(addon); found {
			cmd.RunE = func(cmd *cobra.Command, args []string) error {
				return runCmd(cmd, addon, cmdName, defaultImplementation, args)
			}

			cmdConfig := (*defaultImplementation.Commands)[cmdName]
			if cmdConfig.Cli != nil {
				cmd.Example = cmdConfig.Cli.Examples.String()

				for _, flag := range cmdConfig.Cli.Flags {
					if err := addFlag(flag, cmd.Flags()); err != nil {
						return nil, err
					}
				}
			}

			cmd.Flags().SortFlags = false
			cmd.Flags().PrintDefaults()
		}
	}

	if addonHasOmitFlags(addon, cmdName) {
		addOmitNote(cmd)
	}

	return cmd, nil
}

func addonCommandLongDescription(addon addons.Addon, cmdName string) string {
	if addon.Metadata.Name == "storage" && cmdName == "enable" {
		return "Runs 'enable' for 'storage' addon\n\nNote: only one storage implementation can be enabled at a time. Choose either 'smb' or 'ceph'.\n\nWhen to use:\n- smb: simple share-based storage between K8s nodes and host, suitable for basic/local scenarios\n- ceph: experimental external CephFS-backed file storage for shared and scalable workloads"
	}

	return fmt.Sprintf("Runs '%s' for '%s' addon", cmdName, addon.Metadata.Name)
}

func newImplementationCmd(addon addons.Addon, cmdName string, implementation addons.Implementation) (*cobra.Command, error) {
	implementationName := implementation.Name
	if isExperimentalImplementation(addon, implementation) {
		implementationName = implementationName + " (experimental)"
	}

	cmd := &cobra.Command{
		Use:   implementation.Name,
		Short: fmt.Sprintf("Runs '%s' for '%s' implementation of '%s' addon", cmdName, implementation.Name, addon.Metadata.Name),
		Long:  implementationCommandLongDescription(addon, cmdName, implementation, implementationName),
		Args:  validateAddonCommandArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runCmd(cmd, addon, cmdName, implementation, args)
		},
	}

	cmdConfig := (*implementation.Commands)[cmdName]
	if cmdConfig.Cli != nil {
		cmd.Example = cmdConfig.Cli.Examples.String()

		if err := addFlags(cmdConfig.Cli.Flags, cmd); err != nil {
			return nil, err
		}
	}

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	if cmdConfigHasOmitFlags(cmdConfig) {
		addOmitNote(cmd)
	}

	return cmd, nil
}
func implementationCommandLongDescription(addon addons.Addon, cmdName string, implementation addons.Implementation, implementationDisplayName string) string {
	if addon.Metadata.Name == "storage" && implementation.Name == "ceph" {
		return fmt.Sprintf("Runs '%s' for '%s' implementation of '%s' addon\n\nNote: This implementation is experimental.", cmdName, implementationDisplayName, addon.Metadata.Name)
	}

	return fmt.Sprintf("Runs '%s' for '%s' implementation of '%s' addon", cmdName, implementationDisplayName, addon.Metadata.Name)
}

func isExperimentalImplementation(addon addons.Addon, implementation addons.Implementation) bool {
	if addon.Metadata.Name == "storage" && implementation.Name == "ceph" {
		return true
	}

	return strings.Contains(strings.ToLower(implementation.Description), "experimental")
}

// omitEnableNote informs users that an addon imported without the images of an omitted
// functionality has to be enabled with the same omit option, since the import-time omit
// selection is not persisted.
const omitEnableNote = "Note: When using an addon imported with omitted images, use the same omit option when enabling the addon."

// addonHasOmitFlags reports whether any implementation of the addon declares a CLI flag
// with omittable images for the given command.
func addonHasOmitFlags(addon addons.Addon, cmdName string) bool {
	for _, implementation := range addon.Spec.Implementations {
		if implementation.Commands == nil {
			continue
		}
		if cmdConfigHasOmitFlags((*implementation.Commands)[cmdName]) {
			return true
		}
	}

	return false
}

func cmdConfigHasOmitFlags(cmdConfig addons.AddonCmd) bool {
	if cmdConfig.Cli == nil {
		return false
	}

	return lo.SomeBy(cmdConfig.Cli.Flags, func(flag addons.CliFlag) bool {
		return flag.OmittedImages != nil
	})
}

func addOmitNote(cmd *cobra.Command) {
	if cmd.Long == "" {
		cmd.Long = cmd.Short
	}

	cmd.Long += "\n\n" + omitEnableNote
}

func addFlags(flags []addons.CliFlag, cmd *cobra.Command) error {
	exclusionGroups := map[string][]string{}

	for _, flag := range flags {
		if err := addFlag(flag, cmd.Flags()); err != nil {
			return err
		}

		if flag.ExclusionGroup == nil || *flag.ExclusionGroup == "" {
			continue
		}

		if _, existing := exclusionGroups[*flag.ExclusionGroup]; !existing {
			exclusionGroups[*flag.ExclusionGroup] = []string{flag.Name}
		} else {
			exclusionGroups[*flag.ExclusionGroup] = append(exclusionGroups[*flag.ExclusionGroup], flag.Name)
		}
	}

	for groupName, flagNames := range exclusionGroups {
		if len(flagNames) < 2 {
			slog.Warn("Exclusion group needs more than one flag to be defined", "group", groupName, "flags", flagNames)
			continue
		}

		cmd.MarkFlagsMutuallyExclusive(flagNames...)
	}
	return nil
}

func addFlag(flag addons.CliFlag, flagSet *pflag.FlagSet) error {
	flagDescription, err := flag.FullDescription()
	if err != nil {
		return err
	}

	switch defaultValue := flag.Default.(type) {
	case string:
		if flag.Shorthand != nil {
			flagSet.StringP(flag.Name, *flag.Shorthand, defaultValue, flagDescription)
		} else {
			flagSet.String(flag.Name, defaultValue, flagDescription)
		}
	case bool:
		if flag.Shorthand != nil {
			flagSet.BoolP(flag.Name, *flag.Shorthand, defaultValue, flagDescription)
		} else {
			flagSet.Bool(flag.Name, defaultValue, flagDescription)
		}
	case int:
		if flag.Shorthand != nil {
			flagSet.IntP(flag.Name, *flag.Shorthand, defaultValue, flagDescription)
		} else {
			flagSet.Int(flag.Name, defaultValue, flagDescription)
		}
	case float64:
		if flag.Shorthand != nil {
			flagSet.Float64P(flag.Name, *flag.Shorthand, defaultValue, flagDescription)
		} else {
			flagSet.Float64(flag.Name, defaultValue, flagDescription)
		}
	default:
		return fmt.Errorf("unsupported flag value: %v", defaultValue)
	}

	return nil
}

func runCmd(cmd *cobra.Command, addon addons.Addon, cmdName string, implementation addons.Implementation, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	if addon.Metadata.Name != implementation.Name {
		pterm.Printfln("🤖 Running '%s' for implementation '%s' of '%s' addon", cmdName, implementation.Name, addon.Metadata.Name)
	} else {
		pterm.Printfln("🤖 Running '%s' for '%s' addon", cmdName, addon.Metadata.Name)
	}

	if err := mergeExtraNodeArgs(cmd, args); err != nil {
		return err
	}

	cmdConfig := (*implementation.Commands)[cmdName]
	_, params, err := buildPsCmd(cmd.Flags(), cmdConfig, addon.Directory)
	if err != nil {
		return err
	}
	parameterValues, err := buildParameterValues(cmd.Flags(), cmdConfig)
	if err != nil {
		return err
	}
	if selector := parameterValues["InfraNodeSelector"]; selector != "" {
		if _, err := addonplacement.ParseSelector(selector); err != nil {
			return err
		}
	}

	slog.Debug("Addon command prepared", "command", cmdName, "addon", addon.Metadata.Name, "params", params)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	err = context.Providers().Addon.RunCommand(provider.AddonRunCommandConfig{
		AddonName:       addon.Metadata.Name,
		Implementation:  implementation.Name,
		CommandName:     cmdName,
		AddonDirectory:  addon.Directory,
		ScriptSubPath:   cmdConfig.Script.SubPath,
		Params:          params,
		ParameterValues: parameterValues,
		ShowOutput:      cmd.Flags().Lookup(common.OutputFlagName) != nil && cmd.Flags().Lookup(common.OutputFlagName).Value.String() == "true",
	})
	if err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildPsCmd(flags *pflag.FlagSet, cmdConfig addons.AddonCmd, addonDir string) (cmd string, params []string, err error) {
	cmd = utils.FormatScriptFilePath(filepath.Join(addonDir, cmdConfig.Script.SubPath))
	addParam := func(param string) { params = append(params, param) }

	flags.Visit(func(f *pflag.Flag) {
		if err != nil {
			slog.Debug("Previous error detected, skipping flag", "flag", f.Name)
			return
		}

		err = convertToPsParam(f, cmdConfig, addParam)
	})

	return cmd, params, err
}

func convertToPsParam(flag *pflag.Flag, cmdConfig addons.AddonCmd, add func(string)) error {
	if flag == nil {
		return errors.New("flag must not be nil")
	}

	if flag.Name == common.OutputFlagName {
		add("-ShowLogs")
		return nil
	}

	scriptParam, found := lo.Find(cmdConfig.Script.ParameterMappings, func(mapping addons.ParameterMapping) bool {
		return mapping.CliFlagName == flag.Name
	})

	if !found {
		slog.Warn("CLI flag set, but missing PowerShell parameter mapping in `parameterMappings` of `addon.manifest.yaml`; not parameterized.", "flag", flag.Name, "value", flag.Value)
		return nil
	}

	if flag.Value.Type() == "bool" {
		if flag.Value.String() == "true" {
			add(fmt.Sprintf("-%s", scriptParam.ScriptParameterName))
		} else {
			add(fmt.Sprintf("-%s:$false", scriptParam.ScriptParameterName))
		}
		return nil
	}

	if cmdConfig.Cli == nil {
		return fmt.Errorf("CLI config must not be nil for flag '%s'", flag.Name)
	}

	flagConfig, found := lo.Find(cmdConfig.Cli.Flags, func(f addons.CliFlag) bool {
		return f.Name == flag.Name
	})

	if !found {
		return fmt.Errorf("flag config not found for flag '%s'", flag.Name)
	}

	if err := flagConfig.Constraints.Validate(flag.Value); err != nil {
		return fmt.Errorf("validation error for flag '%s': %v", flag.Name, err)
	}

	if flag.Value.Type() == "string" {
		add(fmt.Sprintf("-%s %s", scriptParam.ScriptParameterName, utils.EscapeWithSingleQuotes(flag.Value.String())))
		return nil
	}

	add(fmt.Sprintf("-%s %v", scriptParam.ScriptParameterName, flag.Value))
	return nil
}

func validateAddonCommandArgs(cmd *cobra.Command, args []string) error {
	normalizedArgs := normalizePositionalArgs(args)
	if len(normalizedArgs) == 0 {
		return nil
	}

	extra := strings.Join(normalizedArgs, " ")
	nodeFlag := cmd.Flags().Lookup("node")
	if nodeFlag != nil {
		nodeVal := strings.TrimSpace(nodeFlag.Value.String())
		if strings.HasSuffix(nodeVal, ",") {
			return fmt.Errorf("unexpected argument(s): %s. It looks like the --node value was split by whitespace after a comma. Use '--node node1,node2' (no spaces) or quote the value, e.g. '--node \"node1, node2\"'", extra)
		}
		if nodeVal != "" {
			return nil
		}
	}

	return fmt.Errorf("unexpected argument(s): %s", extra)
}

func mergeExtraNodeArgs(cmd *cobra.Command, args []string) error {
	normalizedArgs := normalizePositionalArgs(args)
	if len(normalizedArgs) == 0 {
		return nil
	}

	nodeFlag := cmd.Flags().Lookup("node")
	if nodeFlag == nil {
		return fmt.Errorf("unexpected argument(s): %s", strings.Join(normalizedArgs, " "))
	}

	base := strings.TrimSpace(nodeFlag.Value.String())
	if base == "" {
		return fmt.Errorf("unexpected argument(s): %s", strings.Join(normalizedArgs, " "))
	}

	parts := []string{}
	parts = append(parts, strings.Trim(base, " ,"))
	for _, arg := range normalizedArgs {
		// Guard against typos like a misspelled flag (e.g. "--tiime-slices") being
		// silently merged into the node list. Only bare node names are accepted here.
		if strings.HasPrefix(strings.TrimSpace(arg), "-") {
			return fmt.Errorf("unexpected argument(s): %s", strings.Join(normalizedArgs, " "))
		}
		trimmed := strings.Trim(arg, " ,")
		if trimmed == "" {
			continue
		}
		parts = append(parts, trimmed)
	}

	merged := strings.Join(parts, ",")
	if err := cmd.Flags().Set("node", merged); err != nil {
		return fmt.Errorf("failed to normalize --node value: %w", err)
	}

	slog.Warn("Additional positional arguments were interpreted as extra --node values", "normalizedNode", merged)
	return nil
}

func normalizePositionalArgs(args []string) []string {
	normalized := make([]string, 0, len(args))
	for _, arg := range args {
		trimmed := strings.TrimSpace(arg)
		if trimmed == "" {
			continue
		}
		normalized = append(normalized, trimmed)
	}

	return normalized
}

func buildParameterValues(flags *pflag.FlagSet, cmdConfig addons.AddonCmd) (map[string]string, error) {
	values := make(map[string]string)
	var mappingErr error
	flags.Visit(func(flag *pflag.Flag) {
		mapping, found := lo.Find(cmdConfig.Script.ParameterMappings, func(mapping addons.ParameterMapping) bool {
			return mapping.CliFlagName == flag.Name
		})
		if found {
			if flag.Name == "infra-node-selector" {
				values["InfraNodeSelector"] = flag.Value.String()
			} else {
				values[mapping.ScriptParameterName] = flag.Value.String()
			}
		} else if flag.Name == "infra-node-selector" {
			mappingErr = fmt.Errorf("flag '--infra-node-selector' has no script parameter mapping in addon.manifest.yaml")
		}
	})
	return values, mappingErr
}
