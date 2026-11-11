// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package powershell

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"path/filepath"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/os"
	"github.com/k2s-project/k2s/internal/output"
	"github.com/k2s-project/k2s/internal/providers/powershell/decode"
)

type structuredOutputWriter struct {
	isEncodedMessage func(message string) bool
	stdWriter        output.StreamWriter
	rawMessages      []string
}

// ExecutePsWithStructuredResult waits until the command has finished and returns the structured data it received or errors that occurred
// Calls to OutputWriter happen asynchronous
func ExecutePsWithStructuredResult[T any](psScriptPath string, targetType string, writer output.StreamWriter, additionalParams ...string) (v T, err error) {
	if err := platformGuard(); err != nil {
		return v, err
	}

	cmdString := buildCmdString(psScriptPath, targetType, additionalParams...)
	cmdString, err = prepareExecScript(cmdString)
	if err != nil {
		return v, err
	}

	slog.Debug("PS command created", "command", cmdString)

	structuredWriter := &structuredOutputWriter{
		isEncodedMessage: decode.IsEncodedMessage,
		stdWriter:        writer,
		rawMessages:      []string{},
	}
	exe := os.NewCmdExecutor(structuredWriter)

	err = exe.ExecuteCmd(PsCmd, cmdString)
	if err != nil {
		return v, err
	}

	decodedMessage, err := decode.DecodeMessages(structuredWriter.rawMessages, targetType)
	if err != nil {
		return v, err
	}

	return convertToResult[T](decodedMessage)
}

func ExecutePs(script string, writer output.StreamWriter) error {
	if err := platformGuard(); err != nil {
		return err
	}

	script, err := prepareExecScript(script)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", script)

	return os.NewCmdExecutor(writer).ExecuteCmd(PsCmd, script)
}

func (sWriter *structuredOutputWriter) WriteStdOut(message string) {
	if !sWriter.isEncodedMessage(message) {
		sWriter.stdWriter.WriteStdOut(message)
		return
	}

	sWriter.rawMessages = append(sWriter.rawMessages, message)

	slog.Debug("Raw message received")
}

func (sWriter *structuredOutputWriter) WriteStdErr(message string) {
	sWriter.stdWriter.WriteStdErr(message)
}

func (sWriter *structuredOutputWriter) Flush() {
	sWriter.stdWriter.Flush()
}

func buildCmdString(psScriptPath string, targetType string, additionalParams ...string) string {
	builder := strings.Builder{}
	builder.WriteString(psScriptPath)
	builder.WriteString(" -EncodeStructuredOutput -MessageType ")
	builder.WriteString(targetType)

	if len(additionalParams) > 0 {
		for _, param := range additionalParams {
			builder.WriteString(" ")
			builder.WriteString(param)
		}
	}
	return builder.String()
}

func convertToResult[T any](message []byte) (v T, err error) {
	if slog.Default().Enabled(context.Background(), slog.LevelDebug) {
		slog.Debug("Unmarshaling message", "message", string(message))
	}

	err = json.Unmarshal(message, &v)
	if err != nil {
		return v, fmt.Errorf("could not unmarshal message: %w", err)
	}

	slog.Debug("Message unmarshaled")

	return
}

func prepareExecScript(script string) (string, error) {
	slog.Debug("Execution script", "script", script)
	wrapperScript := ""

	installDir, err := os.ExecutableDir()
	if err != nil {
		return "", err
	}

	// check if there is an directory lib folder
	if os.PathExists(filepath.Join(installDir, "lib")) {
		wrapperScript = ("&'" + filepath.Join(installDir, "lib", "scripts", "windows", "host", "base", "Invoke-ExecScript.ps1") + "' -Script ")
	} else {
		// we assume we have a binary under bin path and not in the root
		wrapperScript = ("&'" + filepath.Join(installDir, "..", "lib", "scripts", "windows", "host", "base", "Invoke-ExecScript.ps1") + "' -Script ")
	}
	// The script is passed as a verbatim string, so it reaches Invoke-ExecScript.ps1 exactly as built and is parsed
	// only once by Invoke-Expression. A double-quoted string would already expand $variables, $(sub-expressions)
	// and backtick escapes here, bypassing the single-quote escaping of user-supplied values inside the script.
	wrapperScript += utils.EscapeWithSingleQuotes(script)

	slog.Debug("Final execution script", "script", wrapperScript)

	return wrapperScript, nil
}
