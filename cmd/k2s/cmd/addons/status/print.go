// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package status

import (
	"log/slog"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"fmt"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintSuccess(m ...any)
	PrintWarning(m ...any)
	PrintCyanFg(text string) string
	PrintHeader(m ...any)
	StartSpinner(m ...any) (any, error)
}

type PropPrinter interface {
	PrintProp(prop AddonStatusProp)
}

type JsonPrinter struct {
	terminalPrinter   TerminalPrinter
	marshalIndentFunc func(data any) ([]byte, error)
}

type UserFriendlyPrinter struct {
	terminalPrinter TerminalPrinter
	propPrinter     PropPrinter
}

type AddonPrintStatus struct {
	Name           string            `json:"name"`
	Implementation string            `json:"implementation"`
	Enabled        *bool             `json:"enabled"`
	Props          []AddonStatusProp `json:"props"`
	Error          *string           `json:"error"`
}

type propPrint struct {
	terminalPrinter TerminalPrinter
}

func NewJsonPrinter(terminalPrinter TerminalPrinter, marshalIndentFunc func(data any) ([]byte, error)) *JsonPrinter {
	return &JsonPrinter{
		terminalPrinter:   terminalPrinter,
		marshalIndentFunc: marshalIndentFunc,
	}
}

func NewUserFriendlyPrinter(terminalPrinter TerminalPrinter, propPrinters ...PropPrinter) *UserFriendlyPrinter {
	var propPrinter PropPrinter
	if len(propPrinters) > 0 {
		propPrinter = propPrinters[0]
	} else {
		propPrinter = NewPropPrinter(terminalPrinter)
	}

	return &UserFriendlyPrinter{
		terminalPrinter: terminalPrinter,
		propPrinter:     propPrinter,
	}
}

func NewPropPrinter(terminalPrinter TerminalPrinter) *propPrint {
	return &propPrint{
		terminalPrinter: terminalPrinter,
	}
}

func (s *JsonPrinter) PrintStatus(addonName string, implementation string, loadFunc func(addonName string, implementation string) (*LoadedAddonStatus, error)) error {
	loadedStatus, err := loadFunc(addonName, implementation)
	if err != nil {
		return err
	}

	printStatus := AddonPrintStatus{
		Name: addonName,
	}

	if implementation != "" {
		printStatus.Implementation = implementation
	}

	var deferredErr error
	printStatus.Enabled = loadedStatus.Enabled
	printStatus.Props = loadedStatus.Props

	slog.Info("Marhalling", "status", printStatus)

	bytes, err := s.marshalIndentFunc(printStatus)
	if err != nil {
		return err
	}

	statusJson := string(bytes)

	slog.Info("Printing", "json", statusJson)

	s.terminalPrinter.Println(statusJson)

	return deferredErr
}

func (s *UserFriendlyPrinter) PrintStatus(addonName string, implementation string, loadFunc func(addonName string, implementation string) (*LoadedAddonStatus, error)) error {
	spinner, err := common.StartSpinner(s.terminalPrinter)
	if err != nil {
		return err
	}

	status, err := loadFunc(addonName, implementation)

	common.StopSpinner(spinner)

	if err != nil {
		return err
	}

	if status.Enabled == nil {
		return fmt.Errorf("enabled/disabled info missing for '%s' addon", addonName)
	}

	s.terminalPrinter.PrintHeader("ADDON STATUS")

	coloredAddonName := s.terminalPrinter.PrintCyanFg(addonName)

	if !*status.Enabled {
		if implementation != "" {
			coloredImplemetationName := s.terminalPrinter.PrintCyanFg(implementation)
			s.terminalPrinter.Println("Implementation", coloredImplemetationName, "of Addon", coloredAddonName, "is", s.terminalPrinter.PrintCyanFg("disabled"))
		} else {
			s.terminalPrinter.Println("Addon", coloredAddonName, "is", s.terminalPrinter.PrintCyanFg("disabled"))
		}

		return nil
	}

	if implementation != "" {
		coloredImplemetationName := s.terminalPrinter.PrintCyanFg(implementation)
		s.terminalPrinter.Println("Implementation", coloredImplemetationName, "of Addon", coloredAddonName, "is", s.terminalPrinter.PrintCyanFg("enabled"))
	} else {
		s.terminalPrinter.Println("Addon", coloredAddonName, "is", s.terminalPrinter.PrintCyanFg("enabled"))
	}

	for _, prop := range status.Props {
		s.propPrinter.PrintProp(prop)
	}

	return nil
}

func (s *JsonPrinter) PrintSystemError(addon string, systemError error, systemCmdFailureFunc func() *common.CmdFailure) error {
	printStatus := AddonPrintStatus{
		Name:  addon,
		Error: new(systemError.Error()),
	}

	slog.Info("Marhalling", "status", printStatus)

	bytes, err := s.marshalIndentFunc(printStatus)
	if err != nil {
		return err
	}

	statusJson := string(bytes)

	slog.Info("Printing", "json", statusJson)

	s.terminalPrinter.Println(statusJson)

	failure := systemCmdFailureFunc()
	failure.SuppressCliOutput = true

	return failure
}

func (s *UserFriendlyPrinter) PrintSystemError(_ string, _ error, systemCmdFailureFunc func() *common.CmdFailure) error {
	return systemCmdFailureFunc()
}

func (p *propPrint) PrintProp(prop AddonStatusProp) {
	text := p.GetPropText(prop)

	p.PrintPropText(prop.Okay, text)
}

func (p *propPrint) GetPropText(prop AddonStatusProp) string {
	switch {
	case prop.Okay == nil && prop.Message == nil:
		value := p.terminalPrinter.PrintCyanFg(fmt.Sprint(prop.Value))
		return fmt.Sprintf("%s: %s", prop.Name, value)
	case prop.Okay == nil && prop.Message != nil:
		return p.terminalPrinter.PrintCyanFg(*prop.Message)
	case prop.Okay != nil && prop.Message == nil:
		return fmt.Sprintf("%s: %v", prop.Name, prop.Value)
	default:
		return *prop.Message
	}
}

func (p *propPrint) PrintPropText(okay *bool, text string) {
	switch {
	case okay == nil:
		p.terminalPrinter.Println(text)
	case *okay:
		p.terminalPrinter.PrintSuccess(text)
	default:
		p.terminalPrinter.PrintWarning(text)
	}
}
