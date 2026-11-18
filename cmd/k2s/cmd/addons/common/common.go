// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common

import (
	"fmt"
	"log/slog"
	"sort"
	"strings"

	"github.com/k2s-project/k2s/internal/terminal"

	"github.com/k2s-project/k2s/internal/core/addons"

	"github.com/samber/lo"
)

var defaultImplementations = map[string]string{
	"storage": "smb",
}

func FindDefaultImplementationForAddon(addon addons.Addon) (addons.Implementation, bool) {
	defaultImplementationName, hasDefaultImplementation := defaultImplementations[strings.ToLower(addon.Metadata.Name)]
	if !hasDefaultImplementation {
		return addons.Implementation{}, false
	}

	for _, impl := range addon.Spec.Implementations {
		if strings.EqualFold(impl.Name, defaultImplementationName) {
			return impl, true
		}
	}

	return addons.Implementation{}, false
}

func findDefaultImplementation(allAddons addons.Addons, addonName string) (addons.Addon, addons.Implementation, bool) {
	for _, addon := range allAddons {
		if !strings.EqualFold(addon.Metadata.Name, addonName) {
			continue
		}

		impl, found := FindDefaultImplementationForAddon(addon)
		if found {
			return addon, impl, true
		}
	}

	return addons.Addon{}, addons.Implementation{}, false
}

func findImplementationByCommandName(allAddons addons.Addons, cmdName string) (addons.Addon, addons.Implementation, bool) {
	for _, addon := range allAddons {
		for _, impl := range addon.Spec.Implementations {
			if strings.EqualFold(impl.AddonsCmdName, cmdName) {
				return addon, impl, true
			}
		}
	}

	return addons.Addon{}, addons.Implementation{}, false
}

func collectValidCommandNames(allAddons addons.Addons) []string {
	valid := make([]string, 0)
	for _, addon := range allAddons {
		for _, impl := range addon.Spec.Implementations {
			valid = append(valid, impl.AddonsCmdName)
		}
	}
	sort.Strings(valid)

	return valid
}

type addonInfos struct{ allAddons addons.Addons }

func LogAddons(allAddons addons.Addons) {
	slog.Debug("addons loaded", "count", len(allAddons), "addons", addonInfos{allAddons})
}

// FindImplementation resolves an addon implementation based on command args.
//
// Supported forms:
//   - ["registry"] -> matches AddonsCmdName "registry"
//   - ["ingress", "nginx"] -> matches AddonsCmdName "ingress nginx"
func FindImplementation(allAddons addons.Addons, args []string) (addon addons.Addon, impl addons.Implementation, err error) {
	if len(args) < 1 || len(args) > 2 {
		return addon, impl, fmt.Errorf("expected ADDON [IMPLEMENTATION]")
	}

	if len(args) == 1 {
		defaultAddon, defaultImpl, found := findDefaultImplementation(allAddons, args[0])
		if found {
			return defaultAddon, defaultImpl, nil
		}
	}

	cmdName := args[0]
	if len(args) == 2 {
		cmdName = args[0] + " " + args[1]
	}

	resolvedAddon, resolvedImplementation, found := findImplementationByCommandName(allAddons, cmdName)
	if found {
		return resolvedAddon, resolvedImplementation, nil
	}

	valid := collectValidCommandNames(allAddons)
	return addon, impl, fmt.Errorf("unknown addon '%s' (valid: %s)", cmdName, strings.Join(valid, ", "))
}

// LogValue is a slog.LogValuer implementation to defer the construction of a parameter until the verbosity level is determined
func (ai addonInfos) LogValue() slog.Value {
	infos := lo.Map(ai.allAddons, func(a addons.Addon, _ int) struct {
		Name            string
		Directory       string
		Implementations []string
	} {
		return struct {
			Name            string
			Directory       string
			Implementations []string
		}{Name: a.Metadata.Name, Directory: a.Directory, Implementations: lo.Map(a.Spec.Implementations, func(impl addons.Implementation, index int) string { return impl.Name })}
	})

	return slog.AnyValue(infos)
}

func printValidAddonNames(allAddons addons.Addons, terminalPrinter terminal.TerminalPrinter) {
	tableHeaders := []string{"Available addon names"}
	addonTable := [][]string{tableHeaders}

	for _, addon := range allAddons {
		for _, impl := range addon.Spec.Implementations {
			if addon.Metadata.Name != impl.Name {
				row := []string{string(addon.Metadata.Name + " " + impl.Name)}
				addonTable = append(addonTable, row)
			} else {
				row := []string{string(addon.Metadata.Name)}
				addonTable = append(addonTable, row)
			}
		}
	}
	terminalPrinter.PrintTableWithHeaders(addonTable)
}
