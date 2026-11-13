// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/providers/powershell/decode"
)

func TestBuildRenameScript(t *testing.T) {
	cfg := NodeRenameConfig{OldName: "old-node", NewName: "new-node", Timeout: 15 * time.Minute}

	script, params := buildRenameScript(`C:\k2s`, cfg)
	if !strings.Contains(script, `C:\k2s\lib\scripts\windows\worker\Rename.ps1`) {
		t.Fatalf("unexpected script %q", script)
	}
	want := []string{"-OldName 'old-node'", "-NewName 'new-node'", "-TimeoutSeconds 900"}
	if !slices.Equal(params, want) {
		t.Fatalf("params = %q, want %q", params, want)
	}

	cfg.Force = true
	cfg.ShowOutput = true
	_, params = buildRenameScript(`C:\k2s`, cfg)
	want = append(want, "-Force", "-ShowLogs")
	if !slices.Equal(params, want) {
		t.Fatalf("params = %q, want %q", params, want)
	}
}

// renameScriptMessage encodes a result the way Send-ToCli in the rename script does.
func renameScriptMessage(t *testing.T, payload string) string {
	t.Helper()
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write([]byte(payload)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return "#pm#CmdResult#" + base64.StdEncoding.EncodeToString(compressed.Bytes())
}

func TestRenameScriptResultBecomesCommandFailure(t *testing.T) {
	// Property names as Windows PowerShell serializes the Error object of the script.
	message := renameScriptMessage(t, `{"Error":{"Severity":4,"Code":"node-rename-failed","Message":"Rename a -> b failed while validating target: Node 'a' does not exist. No changes were made."}}`)
	decoded, err := decode.DecodeMessages([]string{message}, "CmdResult")
	if err != nil {
		t.Fatal(err)
	}
	var result psCmdResult
	if err := json.Unmarshal(decoded, &result); err != nil {
		t.Fatal(err)
	}

	var failure *ProviderFailure
	if !errors.As(result.checkFailure(), &failure) {
		t.Fatalf("a failed rename must be reported as a command failure, got %v", result.checkFailure())
	}
	if failure.Severity != SeverityError || failure.Code != "node-rename-failed" || !strings.Contains(failure.Message, "Node 'a' does not exist") {
		t.Fatalf("unexpected failure %+v", failure)
	}
}

func TestRenameScriptResultWithoutErrorIsSuccess(t *testing.T) {
	decoded, err := decode.DecodeMessages([]string{renameScriptMessage(t, `{"Error":null}`)}, "CmdResult")
	if err != nil {
		t.Fatal(err)
	}
	var result psCmdResult
	if err := json.Unmarshal(decoded, &result); err != nil {
		t.Fatal(err)
	}
	if err := result.checkFailure(); err != nil {
		t.Fatalf("unexpected failure %v", err)
	}
}

func TestRenameScriptWithoutResultIsNotSuccess(t *testing.T) {
	if _, err := decode.DecodeMessages(nil, "CmdResult"); err == nil {
		t.Fatal("a script that reports nothing must not count as a successful rename")
	}
}
