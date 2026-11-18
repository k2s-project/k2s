// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package containernetworking

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"strings"

	"github.com/Microsoft/windows-container-networking/cni"
	"github.com/Microsoft/windows-container-networking/common"
	"github.com/Microsoft/windows-container-networking/network"
	kos "github.com/k2s-project/k2s/internal/os"

	"github.com/Microsoft/hcsshim/hcn"
	"github.com/containernetworking/cni/pkg/invoke"
	cniSkel "github.com/containernetworking/cni/pkg/skel"
	cniTypes "github.com/containernetworking/cni/pkg/types"
	cniTypesImpl "github.com/containernetworking/cni/pkg/types/020"
)

// NetPlugin represents the CNI network plugin.
type netPlugin struct {
	*cni.Plugin
	nm network.Manager
}

func NewPlugin(config *common.PluginConfig) (*netPlugin, error) {
	// Setup base plugin.
	plugin, err := cni.NewPlugin("wcn-net", config.Version)
	if err != nil {
		return nil, err
	}

	// Setup network manager.
	nm, err := network.NewManager()
	if err != nil {
		return nil, err
	}

	config.NetApi = nm

	return &netPlugin{
		Plugin: plugin,
		nm:     nm,
	}, nil
}

// Start starts the plugin
func (plugin *netPlugin) Start(config *common.PluginConfig) error {
	// Initialize base plugin.
	err := plugin.Initialize(config)
	if err != nil {
		slog.Error("failed to initialize base plugin", "error", err)
		return err
	}

	slog.Debug("Start plugin", "name", plugin.Name, "version", plugin.Version)

	common.LogNetworkInterfaces()

	// Initialize network manager.
	err = plugin.nm.Initialize(config)
	if err != nil {
		slog.Error("failed to initialize network manager", "error", err)
		return err
	}

	slog.Debug("Plugin started")

	return nil
}

// Stop stops the plugin.
func (plugin *netPlugin) Stop() {
	plugin.nm.Uninitialize()
	plugin.Uninitialize()
	slog.Debug("Plugin stopped")
}

func areVfpRulesEnabled() bool {
	val, ok := os.LookupEnv("BRIDGE_NO_VFPRULES")
	if !ok {
		slog.Debug("VFPRules on")
		return true
	} else {
		if val == "true" {
			slog.Debug("VFPRules false")
			return false
		} else {
			slog.Debug("VFPRules on")
			return true
		}
	}
}

//
// CNI implementation
// https://github.com/containernetworking/cni/blob/master/SPEC.md
//

// Add handles CNI add commands.
// args.ContainerID - ID of the container for which network endpoint is to be added.
// args.Netns - Network Namespace Id (required).
// args.IfName - Interface Name specifies the interface the network should bind to (ex: Ethernet).
// args.Path - Location of the config file.
func (plugin *netPlugin) Add(args *cniSkel.CmdArgs) (resultError error) {
	slog.Debug("ADD command with args", "container-id", args.ContainerID, "net-ns", args.Netns, "if-name", args.IfName, "args", args.Args, "path", args.Path)

	var err error
	var nwConfig *network.NetworkInfo

	podConfig, err := cni.ParseCniArgs(args.Args)
	k8sNamespace := ""
	if err == nil {
		k8sNamespace = string(podConfig.K8S_POD_NAMESPACE)
	}
	slog.Error("ADD", "k8s-namespace", k8sNamespace)

	// Normalize CNI config: replace "type": "bridge" with "type": "sdnbridge" for Windows compatibility
	// The Linux bridge plugin uses "bridge" but Windows expects "sdnbridge" for L2Bridge networks
	normalizedStdinData := strings.Replace(string(args.StdinData), `"type": "bridge"`, `"type": "sdnbridge"`, 1)
	normalizedStdinData = strings.Replace(normalizedStdinData, `"type":"bridge"`, `"type":"sdnbridge"`, 1)

	// Parse network configuration from stdin.
	cniConfig, err := cni.ParseNetworkConfig([]byte(normalizedStdinData))
	if err != nil {
		slog.Error("failed to parse network configuration", "error", err)
		return err
	}

	slog.Debug("Read network configuration", "config", cniConfig)

	if cniConfig.OptionalFlags.EnableDualStack {
		slog.Info("Dual stack is enabled")
	} else {
		slog.Info("Dual stack is disabled")
	}

	// Convert cniConfig to NetworkInfo
	// We don't set namespace, setting namespace is not valid for EP creation
	networkInfo, err := cniConfig.GetNetworkInfo(k8sNamespace)
	if err != nil {
		slog.Error("failed to get network information from network configuration", "error", err)
		return err
	}

	epInfo, err := cniConfig.GetEndpointInfo(networkInfo, args.ContainerID, "")
	if err != nil {
		return err
	}

	epInfo.DualStack = cniConfig.OptionalFlags.EnableDualStack

	// Check for missing namespace
	if args.Netns == "" {
		slog.Error("missing Namespace, cannot add", "endpoint", epInfo)
		return errors.New("cannot create endpoint without a Namespace")
	}
	slog.Error("Namespace found", "net-ns", args.Netns)

	if !cniConfig.OptionalFlags.EnableDualStack {
		nwConfig, err = getOrCreateNetwork(plugin, networkInfo, cniConfig)
	} else {
		// The network must be created beforehand
		nwConfig, err = plugin.nm.GetNetworkByName(cniConfig.Name)

		if nwConfig.Type != hcn.L2Bridge {
			slog.Error("dual stack specified with non l2bridge network", "network-type", nwConfig.Type)
			return errors.New("dual stack specified with non l2bridge network")
		}
	}
	if err != nil {
		return err
	}

	hnsEndpoint, err := plugin.nm.GetEndpointByName(epInfo.Name, cniConfig.OptionalFlags.EnableDualStack)
	if hnsEndpoint != nil {
		slog.Info("Endpoint already exists", "endpoint", hnsEndpoint, "network-id", nwConfig.ID)

		// Endpoint exists
		// Validate for duplication
		if hnsEndpoint.NetworkID == nwConfig.ID {
			// An endpoint already exists in the same network.
			// Do not allow creation of more endpoints on same network
			slog.Debug("Endpoint exists on same network, ignoring add", "endpoint", epInfo)
			// Convert result to the requested CNI version.
			res := cni.GetCurrResult(nwConfig, hnsEndpoint, args.IfName, cniConfig)
			result, err := res.GetAsVersion(cniConfig.CniVersion)
			if err != nil {
				return err
			}

			result.Print()
			return nil
		}
	} else {
		slog.Debug("Creating a new Endpoint")
	}

	// If Ipam was provided, allocate a pool and obtain address
	if cniConfig.Ipam.Type != "" {
		err = allocateIpam(
			networkInfo,
			epInfo,
			cniConfig,
			cniConfig.OptionalFlags.ForceBridgeGateway,
			args.StdinData)
		if err != nil {
			return err
		}
		defer func() {
			if resultError != nil {
				slog.Debug("failure during ADD cleaning-up ipam", "error", err)
				os.Setenv("CNI_COMMAND", "DEL")
				err := deallocateIpam(cniConfig, args.StdinData)

				os.Setenv("CNI_COMMAND", "ADD")
				if err != nil {
					slog.Debug("failed during ADD command for clean-up delegate delete call", "error", err)
				}
			}
		}()
	}

	if cniConfig.OptionalFlags.GatewayFromAdditionalRoutes {
		slog.Debug("GatewayFromAdditionalRoutes set")
		addEndpointGatewaysFromConfig(epInfo, cniConfig)
	}

	// Apply the Network Policy for Endpoint
	epInfo.Policies = append(epInfo.Policies, networkInfo.Policies...)

	// If LoopbackDSR is set, add to policies
	if cniConfig.OptionalFlags.LoopbackDSR {
		hcnLoopbackRoute, _ := network.GetLoopbackDSRPolicy(&epInfo.IPAddress)
		epInfo.Policies = append(epInfo.Policies, hcnLoopbackRoute)
	}

	// dump routes
	if epInfo.Routes != nil {
		for _, route := range epInfo.Routes {
			slog.Debug("XXXX Route", "destination", string(route.Destination.IP), "gateway", string(route.Gateway))
		}
	} else {
		slog.Debug("XXXX No routes available yet")
	}

	epInfo, err = plugin.nm.CreateEndpoint(nwConfig.ID, epInfo, args.Netns)
	if err != nil {
		slog.Error("failed to create endpoint", "error", err)
		return err
	}

	// Convert result to the requested CNI version.
	res := cni.GetCurrResult(nwConfig, epInfo, args.IfName, cniConfig)
	result, err := res.GetAsVersion(cniConfig.CniVersion)
	if err != nil {
		return err
	}

	// Add the extended rules for communication with the host
	hnsEndpointEp, err := plugin.nm.GetEndpointByName(epInfo.Name, cniConfig.OptionalFlags.EnableDualStack)
	if hnsEndpointEp != nil {
		slog.Debug("[cni-net] XXXX Endpoint", "ip-address", string(hnsEndpointEp.IPAddress), "mac-address", string(hnsEndpointEp.MacAddress), "id", string(hnsEndpointEp.ID))

		// check if VFPRules are on
		areVFPRulesOn := areVfpRulesEnabled()
		if areVFPRulesOn {
			// check if executable exists
			path, errWD := os.Getwd()
			if errWD == nil {
				slog.Debug("XXXX Current working directory", "path", path)
			}

			pathExe, errPath := kos.ExecutableDir()
			if errPath != nil {
				slog.Debug("XXXX Current directory", "error", errPath)
				return
			}

			pathCorrected := strings.ReplaceAll(pathExe, "\\\\", "\\")
			// start exe in path where current cni plugin is available
			var executable = pathCorrected + "\\" + "vfprules.exe"

			slog.Debug("XXXX Current exe directory", "path", executable)

			fExec, err := os.Open(executable)
			if err == nil {
				fExec.Close()
				// call tool to add additional VFP rules
				command := executable + " -portid " + string(hnsEndpointEp.ID)

				slog.Debug("XXXX Executing command", "command", command)

				cmd := exec.Command(executable, "-portid", string(hnsEndpointEp.ID))
				// run command
				if err := cmd.Start(); err != nil {
					slog.Debug("XXXX Starting VFP rules executable", "error", err)
				} else {
					slog.Debug("XXXX Starting VFP rules executable successfully")
				}
			}
		}

		// check if enhanced security is on
		if isEnhancedSecurityEnabled() {
			// check annotation
			k8sNamespace := string(podConfig.K8S_POD_NAMESPACE)
			k8sName := string(podConfig.K8S_POD_NAME)

			// start additing configured rules to HNS
			err = hnsProxyAddPoliciesFromConfig(hnsEndpointEp.ID)
			if err != nil {
				slog.Debug("XXXX Apply of proxy policy failed", "error", err)
			}

			// start for L4 proxy handling
			// check if executable exists
			path, errWD := os.Getwd()
			if errWD == nil {
				slog.Debug("XXXX Current working directory", "path", path)
			}

			pathExe, errPath := kos.ExecutableDir()
			if errPath != nil {
				slog.Debug("XXXX Current directory", "error", errPath)
				return
			}

			pathCorrected := strings.ReplaceAll(pathExe, "\\\\", "\\")
			// start exe in path where current cni plugin is available
			var executable = pathCorrected + "\\" + "l4proxy.exe"

			slog.Debug("XXXX Current exe directory", "path", executable)

			fExec, err := os.Open(executable)
			if err == nil {
				fExec.Close()
				// call tool to add additional VFP rules
				command := executable + " -endpointid " + string(hnsEndpointEp.ID) + " -namespace " + k8sNamespace + " -podname " + k8sName

				slog.Debug("XXXX Executing command", "command", command)

				cmd := exec.Command(executable, "-endpointid", string(hnsEndpointEp.ID), "-namespace", k8sNamespace, "-podname", k8sName)
				// run command
				if output, err := cmd.CombinedOutput(); err != nil {
					slog.Debug("XXXX Starting l4proxy executable", "error", err, "output", string(output))
				} else {
					slog.Debug("XXXX Starting l4proxy executable successfully", "output", string(output))
				}
			}
		}
	}

	result.Print()

	slog.Debug("ADD command", "result", result)

	return nil
}

// Delete handles CNI delete commands.
// args.Path - Location of the config file.
func (plugin *netPlugin) Delete(args *cniSkel.CmdArgs) error {
	slog.Debug("Processing DEL command with args", "container-id", args.ContainerID, "net-ns", args.Netns, "if-name", args.IfName, "args", args.Args, "path", args.Path)

	podConfig, err := cni.ParseCniArgs(args.Args)
	k8sNamespace := ""
	if err == nil {
		k8sNamespace = string(podConfig.K8S_POD_NAMESPACE)
	}

	// Normalize CNI config: replace "type": "bridge" with "type": "sdnbridge" for Windows compatibility
	// The Linux bridge plugin uses "bridge" but Windows expects "sdnbridge" for L2Bridge networks
	normalizedStdinData := strings.Replace(string(args.StdinData), `"type": "bridge"`, `"type": "sdnbridge"`, 1)
	normalizedStdinData = strings.Replace(normalizedStdinData, `"type":"bridge"`, `"type":"sdnbridge"`, 1)

	// Parse network configuration from stdin.
	cniConfig, err := cni.ParseNetworkConfig([]byte(normalizedStdinData))
	if err != nil {
		slog.Error("failed to parse network configuration", "error", err)
		return err
	}

	slog.Debug("Read network configuration", "config", cniConfig)

	if cniConfig.Ipam.Type != "" {
		slog.Debug("Ipam detected, executing delegate call to delete ipam", "ipam", cniConfig.Ipam)
		err := deallocateIpam(cniConfig, args.StdinData)

		if err != nil {
			slog.Error("failed during delete call for ipam", "error", err)
			return fmt.Errorf("ipam deletion failed, %v", err)
		}
	}

	// Convert cniConfig to NetworkInfo
	networkInfo, err := cniConfig.GetNetworkInfo(k8sNamespace)
	if err != nil {
		slog.Error("failed to get network information from network configuration", "error", err)
		return err
	}
	epInfo, err := cniConfig.GetEndpointInfo(networkInfo, args.ContainerID, args.Netns)
	if err != nil {
		return err
	}
	endpointInfo, err := plugin.nm.GetEndpointByName(epInfo.Name, cniConfig.OptionalFlags.EnableDualStack)
	if err != nil {
		if hcn.IsNotFoundError(err) {
			slog.Debug("endpoint was not found", "error", err)
			return nil
		}
		slog.Error("failed while getting endpoint", "error", err)
		return err
	}

	// Delete the endpoint.
	err = plugin.nm.DeleteEndpoint(endpointInfo.ID)
	if err != nil {
		if hcn.IsNotFoundError(err) {
			slog.Debug("endpoint was not found", "error", err)
			return nil
		} else {
			slog.Error("failed to delete endpoint", "error", err)
			return err
		}
	}

	slog.Debug("DEL succeeded")

	return nil
}

func addEndpointGatewaysFromConfig(
	endpointInfo *network.EndpointInfo,
	cniConfig *cni.NetworkConfig) {

	defaultDestipv4, defaultDestipv4Network, _ := net.ParseCIDR("0.0.0.0/0")
	defaultDestipv6, defaultDestipv6Network, _ := net.ParseCIDR("::/0")

	for _, addr := range cniConfig.AdditionalRoutes {

		var isv4 bool
		if addr.GW.To4() != nil {
			isv4 = true
		}

		slog.Debug("Entry", "destination", addr.Dst.String(), "gateway", addr.GW.String())

		if isv4 {
			if endpointInfo.Gateway == nil {
				slog.Debug("Found no ipv4 gateway")

				m1, _ := addr.Dst.Mask.Size()
				m2, _ := defaultDestipv4Network.Mask.Size()

				if m1 == m2 &&
					addr.Dst.IP.Equal(defaultDestipv4) {
					endpointInfo.Gateway = addr.GW

					slog.Debug("Assigned ipv4", "gateway", endpointInfo.Gateway.String())
				}
			}
		} else {
			if endpointInfo.Gateway6 == nil {
				slog.Debug("Found no ipv6 gateway")

				m1, _ := addr.Dst.Mask.Size()
				m2, _ := defaultDestipv6Network.Mask.Size()

				if m1 == m2 &&
					addr.Dst.IP.Equal(defaultDestipv6) {
					endpointInfo.Gateway6 = addr.GW

					slog.Debug("Assigned ipv6", "gateway", endpointInfo.Gateway6.String())
				}
			}
		}

		if endpointInfo.Gateway != nil && endpointInfo.Gateway6 != nil {
			break
		}
	}
}

// allocateIpam allocates a pool, then acquires a V4 subnet, endpoint address, and route.
func allocateIpam(
	networkInfo *network.NetworkInfo,
	endpointInfo *network.EndpointInfo,
	cniConfig *cni.NetworkConfig,
	forceBridgeGateway bool,
	networkConfByteStream []byte) error {
	var result cniTypes.Result
	var resultImpl *cniTypesImpl.Result
	var err error

	if cniConfig.OptionalFlags.EnableDualStack {
		result, err = invoke.DelegateAdd(context.TODO(), cniConfig.Ipam.Type, networkConfByteStream, nil)
	} else {
		// It seems the right thing would be to pass the original byte stream instead of the one
		// which cni parsed into NetworkConfig. However to preserve compatibility continue
		// the current behavior when dual stack is not enabled
		result, err = invoke.DelegateAdd(context.TODO(), cniConfig.Ipam.Type, cniConfig.Serialize(), nil)
	}

	if err != nil {
		slog.Info("failed to allocate pool", "error", err)
		return err
	}

	resultImpl, err = cniTypesImpl.GetResult(result)
	if err != nil {
		slog.Debug("failed to allocate pool", "error", err)
		return err
	}

	slog.Debug("IPAM plugin returned", "result", resultImpl)

	if !cniConfig.OptionalFlags.EnableDualStack {
		// Derive the subnet from allocated IP address.
		if resultImpl.IP4 != nil {
			var subnetInfo = network.SubnetInfo{
				AddressPrefix:  resultImpl.IP4.IP,
				GatewayAddress: resultImpl.IP4.Gateway,
			}

			networkInfo.Subnets = append(networkInfo.Subnets, subnetInfo)
			endpointInfo.IPAddress = resultImpl.IP4.IP.IP
			endpointInfo.Gateway = resultImpl.IP4.Gateway

			if forceBridgeGateway {
				endpointInfo.Gateway = resultImpl.IP4.IP.IP.Mask(resultImpl.IP4.IP.Mask)
				endpointInfo.Gateway[3] = 2
			}

			endpointInfo.Subnet = resultImpl.IP4.IP

			for _, route := range resultImpl.IP4.Routes {
				// Only default route is populated when calling HNS, and the below information is not passed
				slog.Debug("XXXX adding routes from ipam")
				endpointInfo.Routes = append(endpointInfo.Routes, network.RouteInfo{Destination: route.Dst, Gateway: route.GW})
			}
		}
	} else {
		if resultImpl.IP4 != nil {

			endpointInfo.IPAddress = resultImpl.IP4.IP.IP
			endpointInfo.IP4Mask = resultImpl.IP4.IP.Mask
			endpointInfo.Gateway = resultImpl.IP4.Gateway

			if forceBridgeGateway {
				endpointInfo.Gateway = resultImpl.IP4.IP.IP.Mask(resultImpl.IP4.IP.Mask)
				endpointInfo.Gateway[3] = 2
			}

			for _, route := range resultImpl.IP4.Routes {
				// Only default route is populated when calling HNS, and the below information is not being passed right now
				slog.Debug("XXXX adding routes from ipam")
				endpointInfo.Routes = append(endpointInfo.Routes, network.RouteInfo{Destination: route.Dst, Gateway: route.GW})
			}
		}

		if resultImpl.IP6 != nil {
			endpointInfo.IPAddress6 = resultImpl.IP6.IP
			endpointInfo.Gateway6 = resultImpl.IP6.Gateway

			for _, route := range resultImpl.IP6.Routes {
				// Only default route is populated when calling HNS, and the below information is not being passed right now
				slog.Debug("XXXX adding routes from ipam")
				endpointInfo.Routes = append(endpointInfo.Routes, network.RouteInfo{Destination: route.Dst, Gateway: route.GW})
			}
		}
	}

	return nil
}

// deallocateIpam performs the cleanup necessary for removing an ipam
func deallocateIpam(cniConfig *cni.NetworkConfig, networkConfByteStream []byte) error {
	if !cniConfig.OptionalFlags.EnableDualStack {
		slog.Info("Delete from ipam when dual stack is disabled")
		return invoke.DelegateDel(context.TODO(), cniConfig.Ipam.Type, cniConfig.Serialize(), nil)
	}

	slog.Info("Delete from ipam when dual stack is enabled")
	return invoke.DelegateDel(context.TODO(), cniConfig.Ipam.Type, networkConfByteStream, nil)
}

// getOrCreateNetwork
// TODO: Require network to be created beforehand and make it an error of the network is not found.
// Once that is done, remove this function.
func getOrCreateNetwork(
	plugin *netPlugin,
	networkInfo *network.NetworkInfo,
	cniConfig *cni.NetworkConfig) (*network.NetworkInfo, error) {
	// Check whether the network already exists.
	nwConfig, err := plugin.nm.GetNetworkByName(cniConfig.Name)
	if err != nil {
		// Network does not exist.
		slog.Info("Creating network")

		nwConfig, err = plugin.nm.CreateNetwork(networkInfo)
		if err != nil {
			slog.Error("failed to create network", "error", err)
			return nil, err
		}

		slog.Debug("Created network", "network-id", nwConfig.ID, "subnet", cniConfig.Ipam.Subnet)
	} else {
		// Network already exists.
		slog.Debug("Found network", "network-id", nwConfig.ID, "subnet", cniConfig.Ipam.Subnet)
	}
	return nwConfig, nil
}

func isEnhancedSecurityEnabled() bool {
	slog.Debug("Checking if enhanced security is enabled")
	// check if a file enhancedsecurity.json is available under programmdata folder
	val, ok := os.LookupEnv("ProgramData")
	if !ok {
		slog.Debug("Enhanced security off, variable not found")
		return false
	}
	// check if marker file is there
	if _, err := os.Stat(val + "\\k2s\\enhancedsecurity.json"); err == nil {
		slog.Debug("Enhanced security on")
		return true
	}

	slog.Debug("Enhanced security off, marker file is not set under programdata folder")

	return false
}

// Check handles CNI CHECK commands.
// args.ContainerID - ID of the container for which network endpoint is to be checked.
// args.Netns - Network Namespace Id (required).
// args.IfName - Interface Name specifies the interface the network should bind to (ex: Ethernet).
// args.Path - Location of the config file.
func (plugin *netPlugin) Check(args *cniSkel.CmdArgs) error {
	slog.Debug("[cni-net] CHECK is currently NOT implemented!", "args", args)
	return nil
}
