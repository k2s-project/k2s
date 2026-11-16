// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package terminal

import (
	"github.com/pterm/pterm"
	"github.com/pterm/pterm/putils"
)

type TerminalPrinter struct {
}

func NewTerminalPrinter() TerminalPrinter {
	return TerminalPrinter{}
}

func (tp TerminalPrinter) Println(m ...any) {
	pterm.Println(m...)
}

func (tp TerminalPrinter) Printfln(format string, a ...any) {
	pterm.Printfln(format, a...)
}

func (tp TerminalPrinter) PrintHeader(m ...any) {
	pterm.Println(pterm.FgLightCyan.Sprint(pterm.BgBlack.Sprint(m...)))
}

func (tp TerminalPrinter) PrintWarning(m ...any) {
	pterm.Warning.Println(m...)
}

func (tp TerminalPrinter) PrintInfoln(m ...any) {
	pterm.Info.Println(m...)
}

func (tp TerminalPrinter) PrintInfofln(format string, a ...any) {
	pterm.Info.Printfln(format, a...)
}

func (tp TerminalPrinter) PrintSuccess(m ...any) {
	pterm.Success.Println(m...)
}

func (tp TerminalPrinter) PrintTreeListItems(items []string) {
	leveledList := pterm.LeveledList{}

	for _, item := range items {
		leveledList = append(leveledList, pterm.LeveledListItem{Level: 0, Text: item})
	}

	root := putils.TreeFromLeveledList(leveledList)

	pterm.DefaultTree.WithRoot(root).Render()
}

func (tp TerminalPrinter) PrintLeveledTreeListItems(rootText string, items []struct {
	Level int
	Text  string
}) {
	leveledList := pterm.LeveledList{}

	for _, item := range items {
		leveledList = append(leveledList, pterm.LeveledListItem{Level: item.Level, Text: item.Text})
	}

	root := putils.TreeFromLeveledList(leveledList)
	root.Text = rootText

	pterm.DefaultTree.WithRoot(root).Render()
}

func (tp TerminalPrinter) StartSpinner(m ...any) (any, error) {
	pSpinner, err := pterm.DefaultSpinner.WithRemoveWhenDone().Start(m...)
	if err != nil {
		return nil, err
	}

	return pSpinner, nil
}

func (tp TerminalPrinter) PrintTableWithHeaders(table [][]string) {
	pterm.DefaultTable.WithHasHeader().WithBoxed().WithData(table).Render()
}

func (tp TerminalPrinter) SPrintTable(separator string, table [][]string) (string, error) {
	return pterm.DefaultTable.WithData(table).WithSeparator(separator).Srender()
}

func (tp TerminalPrinter) PrintRedFg(text string) string {
	return pterm.FgRed.Sprint(text)
}

func (tp TerminalPrinter) PrintGreenFg(text string) string {
	return pterm.FgGreen.Sprint(text)
}

func (tp TerminalPrinter) PrintCyanFg(text string) string {
	return pterm.FgCyan.Sprint(text)
}
