// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package core

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestForwardingDiagnosticTargets(t *testing.T) {
	serviceTargets, err := serviceForwardingTargets(`{"spec":{"clusterIP":"172.21.1.10","ports":[{"port":80,"protocol":"TCP"},{"port":53,"protocol":"UDP"},{"port":0},{"port":65536}]}}`)
	if err != nil {
		t.Fatal(err)
	}
	wantService := []forwardingDiagnosticTarget{{kind: "Service ClusterIP", address: "172.21.1.10", port: 80}}
	if !reflect.DeepEqual(serviceTargets, wantService) {
		t.Fatalf("service targets = %+v, want %+v", serviceTargets, wantService)
	}
	endpointTargets, err := endpointForwardingTargets(`{"items":[
		{"ports":[{"port":8080,"protocol":"TCP"},{"port":53,"protocol":"UDP"},{"port":0},{"port":65536},{}],"endpoints":[{"addresses":["172.20.1.10","not-an-ip"]}]},
		{"ports":[{"port":8080}],"endpoints":[{"addresses":["172.20.1.10","fd00::10"]}]}
	]}`)
	if err != nil {
		t.Fatal(err)
	}
	wantEndpoints := []forwardingDiagnosticTarget{
		{kind: "Pod IP", address: "172.20.1.10", port: 8080},
		{kind: "Pod IP", address: "fd00::10", port: 8080},
	}
	if !reflect.DeepEqual(endpointTargets, wantEndpoints) {
		t.Fatalf("endpoint targets = %+v, want %+v", endpointTargets, wantEndpoints)
	}
}

func TestForwardingDiagnosticInvalidQueries(t *testing.T) {
	if _, err := serviceForwardingTargets("not JSON"); err == nil {
		t.Fatal("invalid Service JSON must fail parsing")
	}
	if _, err := endpointForwardingTargets("not JSON"); err == nil {
		t.Fatal("invalid EndpointSlice JSON must fail parsing")
	}
	targets, err := serviceForwardingTargets(`{"spec":{"clusterIP":"None","ports":[{"port":80}]}}`)
	if err != nil || len(targets) != 0 {
		t.Fatalf("headless service must not produce an IP probe: %+v, %v", targets, err)
	}
}

func TestForwardingDiagnosticsProbeAllPathsDespiteCurlFailure(t *testing.T) {
	var hostURLs, podURLs []string
	kubectl := func(_ context.Context, args ...string) (string, error) {
		if args[0] == "exec" {
			podURLs = append(podURLs, args[len(args)-1])
			return "", errors.New("Service timeout")
		}
		if args[1] == "service" {
			return `{"spec":{"clusterIP":"172.21.1.10","ports":[{"port":80}]}}`, nil
		}
		return `{"items":[{"ports":[{"port":8080}],"endpoints":[{"addresses":["172.20.1.10","fd00::10"]}]}]}`, nil
	}
	curl := func(_ context.Context, args ...string) (string, error) {
		hostURLs = append(hostURLs, args[len(args)-1])
		return "", errors.New("Service timeout")
	}
	collectWindowsForwardingDiagnostics(context.Background(), []string{"albums-win1"}, kubectl, curl)
	want := []string{
		"http://albums-win1.k2s.svc.cluster.local:80/albums-win1",
		"http://172.21.1.10:80/albums-win1",
		"http://172.20.1.10:8080/albums-win1",
		"http://[fd00::10]:8080/albums-win1",
	}
	if !reflect.DeepEqual(hostURLs, want) || !reflect.DeepEqual(podURLs, want) {
		t.Fatalf("paths missing: host=%v pod=%v want=%v", hostURLs, podURLs, want)
	}
}

func TestForwardingDiagnosticsContinueAfterUnavailableService(t *testing.T) {
	var URLs []string
	kubectl := func(_ context.Context, args ...string) (string, error) {
		switch {
		case args[0] == "exec":
			return "", nil
		case args[1] == "service":
			return "", errors.New("API query failed")
		default:
			return `{"items":[{"ports":[{"port":80}],"endpoints":[{"addresses":["172.20.1.10"]}]}]}`, nil
		}
	}
	curl := func(_ context.Context, args ...string) (string, error) {
		URLs = append(URLs, args[len(args)-1])
		return "", nil
	}
	collectWindowsForwardingDiagnostics(context.Background(), []string{"albums-win1"}, kubectl, curl)
	if len(URLs) != 2 || !strings.Contains(URLs[1], "172.20.1.10") {
		t.Fatalf("DNS and endpoint probes should still run: %v", URLs)
	}
}

func TestForwardingDiagnosticsRespectCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	run := func(context.Context, ...string) (string, error) {
		t.Fatal("no diagnostics should launch after context cancellation")
		return "", nil
	}
	collectWindowsForwardingDiagnostics(ctx, []string{"albums-win1"}, run, run)
}

func TestBoundedDiagnosticKeepsStderrOutOfJSON(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	output, err := runBoundedDiagnostic(context.Background(), executable, "-test.run=^TestDiagnosticProcessHelper$", "--", "output")
	if err != nil {
		t.Fatal(err)
	}
	if output != `{"spec":{"clusterIP":"172.21.1.10","ports":[{"port":80}]}}` {
		t.Fatalf("stderr contaminated JSON: %q", output)
	}
}

func TestBoundedDiagnosticReportsFailureAndPartialOutput(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	output, err := runBoundedDiagnostic(context.Background(), executable, "-test.run=^TestDiagnosticProcessHelper$", "--", "failure")
	if err == nil || output != "partial evidence" {
		t.Fatalf("failed command must preserve partial output and error: %q, %v", output, err)
	}
}

func TestBoundedDiagnosticRespectsCollectionDeadline(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err = runBoundedDiagnostic(ctx, executable, "-test.run=^TestDiagnosticProcessHelper$", "--", "sleep")
	if err == nil || ctx.Err() != context.DeadlineExceeded || time.Since(start) > 5*time.Second {
		t.Fatalf("command did not honor aggregate deadline: %v, %v, elapsed %v", err, ctx.Err(), time.Since(start))
	}
}

func TestDiagnosticProcessHelper(t *testing.T) {
	if len(os.Args) < 3 || os.Args[len(os.Args)-2] != "--" {
		return
	}
	switch os.Args[len(os.Args)-1] {
	case "output":
		fmt.Fprint(os.Stderr, "diagnostic warning")
		fmt.Fprint(os.Stdout, `{"spec":{"clusterIP":"172.21.1.10","ports":[{"port":80}]}}`)
		os.Exit(0)
	case "failure":
		fmt.Fprint(os.Stdout, "partial evidence")
		fmt.Fprint(os.Stderr, "command failed")
		os.Exit(2)
	case "sleep":
		time.Sleep(30 * time.Second)
		os.Exit(0)
	default:
		t.Fatal("unknown helper mode")
	}
}
