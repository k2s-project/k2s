// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"errors"
	"flag"
	"io/fs"
	"log/slog"
	"os"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/internal/logging"

	"gopkg.in/yaml.v3"
)

func main() {
	inputFile := flag.String("input", "", "The YAML input file path")
	outputFile := flag.String("output", "", "The JSON output file path")
	indent := flag.Bool("indent", false, "JSON gets indented for readability if set to TRUE")
	verbosity := flag.String(cli.VerbosityFlagName, logging.LevelToLowerString(slog.LevelInfo), cli.VerbosityFlagHelp())

	flag.Parse()

	var levelVar = new(slog.LevelVar)
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: levelVar})))

	logging.SetVerbosity(*verbosity, levelVar)

	slog.Info("yaml2json started", "input", *inputFile, "output", *outputFile, "indent", *indent, cli.VerbosityFlagName, *verbosity)

	if err := validateFlags(*inputFile, *outputFile); err != nil {
		slog.Error("validation error occurred", "error", err)
		os.Exit(1)
	}

	if err := yaml2json(*inputFile, *outputFile, *indent); err != nil {
		slog.Error("error occurred while converting yaml to json", "error", err)
		os.Exit(1)
	}

	slog.Info("yaml2json finished")
}

func yaml2json(inputFile string, outputFile string, indent bool) error {
	rawData, err := os.ReadFile(inputFile)
	if err != nil {
		return err
	}

	yamlData := make(map[string]interface{})

	if err := yaml.Unmarshal(rawData, &yamlData); err != nil {
		return err
	}

	var jsonData []byte
	if indent {
		jsonData, err = json.MarshalIndent(yamlData, "", "	")
	} else {
		jsonData, err = json.Marshal(yamlData)
	}

	if err != nil {
		return err
	}

	return os.WriteFile(outputFile, jsonData, fs.ModePerm)
}

func validateFlags(inputFile string, outputFile string) error {
	if inputFile == "" {
		return errors.New("input file path must not be empty")
	}

	if outputFile == "" {
		return errors.New("output file path must not be empty")
	}

	if _, err := os.Stat(inputFile); os.IsNotExist(err) {
		return errors.New("input file does not exist")
	}

	return nil
}
