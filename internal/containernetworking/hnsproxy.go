// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package containernetworking

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Microsoft/hcsshim/hcn"
	"github.com/k2s-project/k2s/internal/logging"
	kos "github.com/k2s-project/k2s/internal/os"
)

type Policy struct {
	// Inbound proxy port. (Required)
	InboundProxyPort string

	// Outbound proxy port. (Required)
	OutboundProxyPort string

	// Ignore traffic originating from the specified user SID. (Optional)
	UserSID string

	// Only proxy traffic originating from the specified address. (Optional)
	LocalAddresses string

	// Only proxy traffic destinated to the specified address. (Optional)
	RemoteAddresses string

	// Only proxy traffic originating from the specified port or port range. (Optional)
	LocalPorts string

	// Only proxy traffic destinated to the specified port or port range. (Optional)
	RemotePorts string

	// The priority of this policy. (Optional)
	// For more info, see https://docs.microsoft.com/en-us/windows/win32/fwp/filter-weight-assignment.
	Priority uint16

	// Only proxy traffic using this protocol. TCP is the only supported
	// protocol for now, and this field defaults to that if left blank. (Optional)
	// Ex: 6 = TCP
	Protocol string

	// Inbound port exceptions
	InboundPortExceptions []string

	// Inbound address exceptions
	InboundAddressExceptions []string

	// Outbound port exceptions
	OutboundPortExceptions []string

	// Outbound address exceptions
	OutboundAddressExceptions []string
}

type HnsProxyConfig struct {
	InboundProxyPort          string `json:"inboundproxyport"`
	OutboundProxyPort         string `json:"outboundproxyport"`
	InboundPortExceptions     string `json:"inboundportexceptions"`
	InboundAddressExceptions  string `json:"inboundaddressexceptions"`
	OutboundPortExceptions    string `json:"outboundportexceptions"`
	OutboundAddressExceptions string `json:"outboundaddressexceptions"`
}

type VfpRoutes struct {
	HnsProxyConfig HnsProxyConfig `json:"hnsproxyconfig"`
}

func hnsProxyAddPolicy(hnsEndpointID string, policy Policy) error {
	if err := hnsProxyValidatePolicy(policy); err != nil {
		return err
	}

	// TCP is the default protocol and is the only supported one anyway.
	policy.Protocol = "6"

	policySetting := hcn.L4WfpProxyPolicySetting{
		InboundProxyPort:  policy.InboundProxyPort,
		OutboundProxyPort: policy.OutboundProxyPort,
		UserSID:           policy.UserSID,
		FilterTuple: hcn.FiveTuple{
			LocalAddresses:  policy.LocalAddresses,
			RemoteAddresses: policy.RemoteAddresses,
			LocalPorts:      policy.LocalPorts,
			RemotePorts:     policy.RemotePorts,
			Protocols:       policy.Protocol,
			Priority:        policy.Priority,
		},
		InboundExceptions:  hcn.ProxyExceptions{IpAddressExceptions: policy.InboundAddressExceptions, PortExceptions: policy.InboundPortExceptions},
		OutboundExceptions: hcn.ProxyExceptions{IpAddressExceptions: policy.OutboundAddressExceptions, PortExceptions: policy.OutboundPortExceptions},
	}

	policyJSON, err := json.Marshal(policySetting)
	if err != nil {
		// log error
		log.Println("Error marshaling to json:", err)
		return err
	}

	// log on console the JSON
	log.Println("Policy JSON:", string(policyJSON))

	endpointPolicy := hcn.EndpointPolicy{
		Type:     hcn.L4WFPPROXY,
		Settings: policyJSON,
	}

	request := hcn.PolicyEndpointRequest{
		Policies: []hcn.EndpointPolicy{endpointPolicy},
	}

	endpoint, err := hcn.GetEndpointByID(hnsEndpointID)
	if err != nil {
		log.Println("Error getting endpoint:", err)
		return err
	}

	err1 := endpoint.ApplyPolicy(hcn.RequestTypeAdd, request)
	if err1 != nil {
		log.Println("Error applying policy	:", err1)
		return err1
	}
	return nil
}

// ClearPolicies removes all the proxy policies from the specified endpoint.
// It returns the number of policies that were removed, which will be zero
// if an error occurred or if the endpoint did not have any active proxy policies.
func HnsProxyClearPolicies(hnsEndpointID string) (numRemoved int, err error) {
	fmt.Println("Clear the policies for endpoint: ", hnsEndpointID)
	policies, err := hnsProxyListPolicies(hnsEndpointID)
	if err != nil {
		return 0, err
	}

	policyReq := hcn.PolicyEndpointRequest{
		Policies: policies,
	}

	policyJSON, err := json.Marshal(policyReq)
	if err != nil {
		return 0, err
	}

	modifyReq := &hcn.ModifyEndpointSettingRequest{
		ResourceType: hcn.EndpointResourceTypePolicy,
		RequestType:  hcn.RequestTypeRemove,
		Settings:     policyJSON,
	}

	return len(policies), hcn.ModifyEndpointSettings(hnsEndpointID, modifyReq)
}

func hnsProxyListPolicies(hnsEndpointID string) ([]hcn.EndpointPolicy, error) {
	endpoint, err := hcn.GetEndpointByID(hnsEndpointID)
	if err != nil {
		return nil, err
	}

	var policies []hcn.EndpointPolicy
	for _, policy := range endpoint.Policies {
		if policy.Type == hcn.L4WFPPROXY {
			policies = append(policies, policy)
		}
	}

	return policies, nil
}

func hnsProxyValidatePolicy(policy Policy) error {
	if len(policy.InboundProxyPort) == 0 {
		return errors.New("policy missing proxy port")
	}
	port, _ := strconv.Atoi(policy.InboundProxyPort)
	if port == 0 {
		return errors.New("policy has invalid proxy port value: 0")
	}
	return nil
}

func hnsProxyGetConfig() (*VfpRoutes, error) {
	defer logging.LogExecutionTime(time.Now(), "getVfpRoutes")

	directoryOfExecutable, err := kos.ExecutableDir()
	if err != nil {
		panic(err)
	}

	routeConfJsonFp := directoryOfExecutable + "\\vfprules.json"
	routeConfJsonFile, err := os.Open(routeConfJsonFp)
	if err != nil {
		slog.Error("unable to open file", "path", routeConfJsonFp, "error", err)
		return nil, fmt.Errorf("unable to open file %s: %w", routeConfJsonFp, err)
	}
	defer routeConfJsonFile.Close()

	routesConfJsonBytes, err := io.ReadAll(routeConfJsonFile)
	if err != nil {
		slog.Error("unable to read file", "path", routeConfJsonFp, "error", err)
		return nil, fmt.Errorf("unable to read file %s: %w", routeConfJsonFp, err)
	}

	var vfpRoutes VfpRoutes

	err = json.Unmarshal(routesConfJsonBytes, &vfpRoutes)
	if err != nil {
		slog.Error("unable to unmarshal json", "path", routeConfJsonFp, "error", err)
		return nil, fmt.Errorf("unable to unmarshal json %s: %w", routeConfJsonFp, err)
	}

	return &vfpRoutes, nil
}

func hnsProxyAddPoliciesFromConfig(hnsEndpointID string) (err error) {
	slog.Debug("Add the policies from config", "endpoint", hnsEndpointID)

	// retrieve configuration
	vfpRoutes, err1 := hnsProxyGetConfig()
	if err1 != nil {
		log.Fatalf("Fatal error in applying the vfp rules: %s", err1)
		return err1
	}

	// create array objects
	var inboundportexceptionsArray []string
	if vfpRoutes.HnsProxyConfig.InboundPortExceptions != "" {
		inboundportexceptionsArray = strings.Split(vfpRoutes.HnsProxyConfig.InboundPortExceptions, ",")
	}
	var inboundaddressexceptionsArray []string
	if vfpRoutes.HnsProxyConfig.InboundAddressExceptions != "" {
		inboundaddressexceptionsArray = strings.Split(vfpRoutes.HnsProxyConfig.InboundAddressExceptions, ",")
	}
	var outboundportexceptionsArray []string
	if vfpRoutes.HnsProxyConfig.OutboundPortExceptions != "" {
		outboundportexceptionsArray = strings.Split(vfpRoutes.HnsProxyConfig.OutboundPortExceptions, ",")
	}
	var outboundaddressexceptionsArray []string
	if vfpRoutes.HnsProxyConfig.OutboundAddressExceptions != "" {
		outboundaddressexceptionsArray = strings.Split(vfpRoutes.HnsProxyConfig.OutboundAddressExceptions, ",")
	}

	// creaty an policy object and copy from vfpRoutes
	userid := "S-1-5-32-556"
	policy := Policy{
		InboundProxyPort:          vfpRoutes.HnsProxyConfig.InboundProxyPort,
		OutboundProxyPort:         vfpRoutes.HnsProxyConfig.OutboundProxyPort,
		UserSID:                   userid,
		LocalAddresses:            "",
		RemoteAddresses:           "",
		LocalPorts:                "",
		RemotePorts:               "",
		Priority:                  0,
		InboundPortExceptions:     inboundportexceptionsArray,
		InboundAddressExceptions:  inboundaddressexceptionsArray,
		OutboundPortExceptions:    outboundportexceptionsArray,
		OutboundAddressExceptions: outboundaddressexceptionsArray,
	}

	slog.Default().WithGroup("policy").Debug("Policy",
		"endpoint-id", hnsEndpointID,
		"inbound-proxy-port", policy.InboundProxyPort,
		"outbound-proxy-port", policy.OutboundProxyPort,
		"user-sid", policy.UserSID,
		"local-addresses", policy.LocalAddresses,
		"remote-addresses", policy.RemoteAddresses,
		"local-ports", policy.LocalPorts,
		"remote-ports", policy.RemotePorts,
		"priority", policy.Priority,
		"protocol", policy.Protocol,
		"inbound-port-exceptions", policy.InboundPortExceptions,
		"inbound-address-exceptions", policy.InboundAddressExceptions,
		"outbound-port-exceptions", policy.OutboundPortExceptions,
		"outbound-address-exceptions", policy.OutboundAddressExceptions)

	err2 := hnsProxyAddPolicy(hnsEndpointID, policy)
	if err2 != nil {
		log.Fatalf("Fatal error in adding the policy: %s", err2)
		return err2
	}
	return nil
}
