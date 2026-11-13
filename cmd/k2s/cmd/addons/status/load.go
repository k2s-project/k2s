// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package status

import (
	"fmt"

	"github.com/k2s-project/k2s/internal/provider"
)

type LoadedAddonStatus struct {
	Enabled *bool             `json:"enabled"`
	Props   []AddonStatusProp `json:"props"`
}

type AddonStatusProp struct {
	Value   any     `json:"value"`
	Okay    *bool   `json:"okay"`
	Message *string `json:"message"`
	Name    string  `json:"name"`
}

func LoadAddonStatus(addonProv provider.AddonProvider, addonName string, addonDirectory string) (*LoadedAddonStatus, error) {
	result, err := addonProv.Status(provider.AddonStatusConfig{
		Name:      addonName,
		Directory: addonDirectory,
	})
	if err != nil {
		return nil, fmt.Errorf("could not load addon status for '%s': %w", addonName, err)
	}

	// Map provider result to LoadedAddonStatus
	for _, a := range result.Addons {
		if a.Name == addonName {
			loaded := &LoadedAddonStatus{
				Enabled: new(a.Enabled),
			}
			for _, p := range a.Props {
				loaded.Props = append(loaded.Props, AddonStatusProp{
					Name:    p.Name,
					Value:   p.Value,
					Okay:    p.Okay,    // preserve nil for informational props
					Message: p.Message, // preserve optional display message
				})
			}
			return loaded, nil
		}
	}

	// Addon not found in status result
	return &LoadedAddonStatus{Enabled: new(false)}, nil
}
