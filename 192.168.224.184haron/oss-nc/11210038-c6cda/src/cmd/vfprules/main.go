// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/internal/logging"
	kos "github.com/k2s-project/k2s/internal/os"
	ve "github.com/k2s-project/k2s/internal/version"

	"github.com/google/uuid"
)

type VfpRoute struct {
	Name     string `json:"name"`
	Subnet   string `json:"subnet"`
	Gateway  string `json:"gateway"`
	Priority string `json:"priority"`
}

type VfpRoutes struct {
	Routes []VfpRoute `json:"routes"`
	VfpApi []string   `json:"vfpapi"`
}

const cliName = "vfprules"

var (
	portid                = ""
	directoryOfExecutable string
)

func init() {
	var err error
	directoryOfExecutable, err = kos.ExecutableDir()
	if err != nil {
		panic(err)
	}
}

func main() {
	versionFlag := cli.NewVersionFlag(cliName)
	flag.StringVar(&portid, "portid", portid, "portid of the new port created (GUID). Please use lowercase !")
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}

	if isValidUUID(portid) {
		fmt.Println("VFPRules starting with portid:", portid)
	} else {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage of %s:\n", os.Args[0])
		flag.PrintDefaults()
		return
	}

	logDir := filepath.Join(logging.RootLogDir(), cliName)
	logFileName := cliName + "-" + portid + ".log"

	logFile, err := logging.SetupDefaultFileLogger(logDir, logFileName, slog.LevelDebug, "component", cliName, "scope", "[cni-net]")
	if err != nil {
		slog.Error("failed to setup file logger", "error", err)
		os.Exit(1)
	}
	defer logFile.Close()

	slog.Debug("Started", "portid", portid)

	vfpRoutes, err := getVfpRoutes()
	if err != nil {
		log.Fatalf("Fatal error in applying the vfp rules: %s", err)
	}

	errAdd := addVfpRules(portid, vfpRoutes, logDir)
	if errAdd != nil {
		log.Fatalf("Fatal error in applying the vfp rules: %s", errAdd)
	}

	err = logging.CleanLogDir(logDir, 24*time.Hour)
	if err != nil {
		slog.Error("failed to clean up log dir", "error", err)
		os.Exit(1)
	}

	fmt.Printf("%s finished, please checks logs in %s\n", cliName, logFile.Name())
}

func getPort(name string, logDir string) (string, error) {
	slog.Debug("GetPort for port", "name", name)

	// open file for writing ports
	filename := filepath.Join(logDir, "vfp-ports-"+name+".log")
	file, err := os.OpenFile(filename, os.O_CREATE|os.O_WRONLY, os.FileMode(0777))
	if err != nil {
		log.Fatalf("failed opening file: %s", err)
	}

	cmd := exec.Command("vfpctrl", "/list-vmswitch-port")
	cmd.Stdout = file

	if err := cmd.Run(); err != nil {
		slog.Error("get port name", "error", err)
		file.Close()
		return "", err
	} else {
		slog.Debug("Get port name successful")
	}
	file.Close()
	// read file line by line and parse
	readFile, err := os.Open(filename)
	if err != nil {
		slog.Error("get port name: failed to open file", "error", err)
		return "", err
	}
	// scan the whole file
	scanner := bufio.NewScanner(readFile)
	scanner.Split(bufio.ScanLines)
	lastportname := ""
	found := false
	for scanner.Scan() {
		line := scanner.Text()
		s := strings.Split(line, ":")
		if len(s) > 1 {
			// keep port name
			param := strings.TrimSpace(s[0])
			if param == "Port name" {
				lastportname = s[1]
			}

			// check switch name
			if param == "Port Friendly name" {
				value := strings.TrimSpace(s[1])
				valuelower := strings.ToLower(value)
				namelower := strings.ToLower(name)
				slog.Debug("Comparing", "compare-value", valuelower, "compare-name", namelower)
				if valuelower == namelower {
					found = true
					break
				}
			}
		}
	}
	readFile.Close()

	if found {
		return strings.TrimSpace(lastportname), nil
	}
	slog.Error("get port: no entry found yet", "portid", portid)
	return "", errors.New("no entry found")
}

func writeVFPRule(datawriter *bufio.Writer, name, port, macgateway, subnet, priority string) error {
	command := "C:\\Windows\\System32\\vfpctrl.exe /port " + port + " /layer VNET_PA_ROUTE_LAYER /group VNET_GROUP_PA_ROUTE_IPV4_OUT /add-rule-ex "
	rulex := "\"" + name + " " + name + " * * * " + subnet + " * 128 * " + priority + " transpose *,0/*,0 modify 00-00-00-00-00-00 " + macgateway + "\""
	// use echo to format correctly
	stringunformated := command + rulex
	bytes, errWrite := datawriter.WriteString(stringunformated + "\n")
	if errWrite != nil {
		log.Fatalf("failed writing file: %s, bytes: %s", errWrite, string(bytes))
	}
	return errWrite
}

func getMacOfGateway(ipgateway string) (string, error) {
	slog.Debug("GetMacOfGateway", "ipgateway", ipgateway)
	// get all the system's or local machine's network interfaces
	var currentNetworkHardwareName string
	currentNetworkHardwareName = ""
	interfaces, _ := net.Interfaces()
	for _, interf := range interfaces {
		if addrs, err := interf.Addrs(); err == nil {
			for index, addr := range addrs {
				slog.Debug("GetMacOfGateway", "index", index, "interface", interf.Name, "address", addr.String())
				// only interested in the name with current IP address
				if strings.Contains(addr.String(), ipgateway) {
					slog.Debug("Using interface", "name", interf.Name)
					currentNetworkHardwareName = interf.Name
				}
			}
		}
	}

	if len(currentNetworkHardwareName) == 0 {
		slog.Debug("GetMacOfGateway: No gateway found with this ip", "ip-address", ipgateway)
		return "", errors.New("No gateway found as configured: " + ipgateway)
	}

	slog.Debug("GetMacOfGateway", "current-hw-name", currentNetworkHardwareName)

	// extract the hardware information base on the interface name
	// capture above
	netInterface, err := net.InterfaceByName(currentNetworkHardwareName)
	if err != nil {
		fmt.Println(err)
		return "", err
	}
	name := netInterface.Name
	macAddress := netInterface.HardwareAddr

	slog.Debug("GetMacOfGateway", "hw-name", name, "mac-address", macAddress.String())

	hwAddr, err := net.ParseMAC(macAddress.String())
	if err != nil {
		slog.Debug("GetMacOfGateway: unable to parse MAC address", "error", err)
		return "", err
	}
	macUpper := strings.ToUpper(hwAddr.String())
	returnMac := strings.Replace(macUpper, ":", "-", 5)
	slog.Debug("GetMacOfGateway: physical HW address", "mac-address", returnMac)
	return returnMac, err
}

func addVfpRules(portid string, vfpRoutes *VfpRoutes, logDir string) error {
	// get the port related to id
	fmt.Println("Searching for port: ", portid, " ...")
	found, port := false, ""
	for i := 1; i < 30 && !found; i++ {
		var errPort error
		port, errPort = getPort(portid, logDir)
		if errPort == nil {
			slog.Debug("Result of get port", "port", port)
			found = true
			break
		}
		time.Sleep(1000 * time.Millisecond)
	}

	if !found {
		slog.Error("Port not found", "port-id", port)
		return errors.New("port was not found")
	}

	// get version of windows OS
	cmd := exec.Command("cmd", "/c", "ver")
	output, err := cmd.Output()
	if err != nil {
		slog.Error("failed to determine Windows version", "error", err)
		return err
	}
	slog.Debug("Windows version determined", "version", string(output))

	// check if version is matching version from vfpRoutes.VfpApi
	vfpapi := false
	if len(vfpRoutes.VfpApi) > 0 {
		// check if version is matching
		version := strings.TrimSpace(string(output))
		for _, v := range vfpRoutes.VfpApi {
			if strings.Contains(version, v) {
				vfpapi = true
				break
			}
		}
	}

	// add the rules with the vfp ctrl exe
	if vfpapi {
		// adding vfp rules works with vfpapi.dll
		slog.Debug("Using vfpapi for adding rules because this was configured in the vfprules.json")
		fmt.Println("VfpAPi is configured for this version of windows: ", string(output))
		err := addVfpRulesWithVfpApi(portid, port, vfpRoutes, logDir)
		if err != nil {
			slog.Error("failed to add VFP rules with vfpapi.dll", "error", err)
			return err
		}
	} else {
		// adding vfp rules works with vfpctrl.exe
		slog.Debug("Using vfpctrl for adding rules, no version matches in vfprules.json")
		fmt.Println("VfpCtrl will be used for this version of windows: ", string(output))
		err := addVfpRulesWithVfpCtrlExe(portid, port, vfpRoutes, logDir)
		if err != nil {
			slog.Error("failed to add VFP rules with vfpctrl.exe", "error", err)
			return err
		}
	}

	return nil
}

func isValidUUID(u string) bool {
	_, err := uuid.Parse(u)
	return err == nil
}

func getVfpRoutes() (*VfpRoutes, error) {
	defer logging.LogExecutionTime(time.Now(), "getVfpRoutes")
	configPath := directoryOfExecutable + "\\vfprules.json"
	configFile, err := os.Open(configPath)
	if err != nil {
		slog.Error("unable to open file", "file", configPath, "error", err)
		return nil, fmt.Errorf("[cni-net] unable to open file: %s, error: %w", configPath, err)
	}
	defer configFile.Close()

	routesConfJsonBytes, err := io.ReadAll(configFile)
	if err != nil {
		slog.Error("unable to read file", "file", configPath, "error", err)
		return nil, fmt.Errorf("[cni-net] unable to read file: %s, error: %w", configPath, err)
	}

	var vfpRoutes VfpRoutes

	err = json.Unmarshal(routesConfJsonBytes, &vfpRoutes)
	if err != nil {
		slog.Error("unable to unmarshal file", "file", configPath, "error", err)
		return nil, fmt.Errorf("[cni-net] unable to unmarshal file: %s, error: %w", configPath, err)
	}

	return &vfpRoutes, nil
}

func addVfpRulesWithVfpCtrlExe(portid string, port string, vfpRoutes *VfpRoutes, logDir string) error {
	// open file for adding commands
	filename := filepath.Join(logDir, "vfp-rules-"+portid+".cmd")
	fileCmds, errCmds := os.OpenFile(filename, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if errCmds != nil {
		log.Fatalf("AddVfpRulesWithVfpCtrlExe: Failed creating file: %s", errCmds)
		return errCmds
	}

	datawriter := bufio.NewWriter(fileCmds)
	for _, vfpRoute := range vfpRoutes.Routes {
		slog.Info("addVfpRulesWithVfpCtrlExe", "name", vfpRoute.Name, "subnet", vfpRoute.Subnet, "gateway", vfpRoute.Gateway, "priority", vfpRoute.Priority)
		// get mac address of gateway
		mac, errmac := getMacOfGateway(vfpRoute.Gateway)
		if errmac != nil {
			slog.Info("AddVfpRulesWithVfpCtrlExe: Getting MAC not found error, will continue with the other rules", "error", errmac)
		} else {
			// write the rules to be added
			writeVFPRule(datawriter, vfpRoute.Name, port, mac, vfpRoute.Subnet, vfpRoute.Priority)
		}
	}
	datawriter.Flush()
	fileCmds.Close()

	slog.Debug("Command file should be available", "file-name", filename)

	// try more times if needed
	execution := false
	for j := 1; j < 4 && !execution; j++ {
		cmd := exec.Command("cmd", "/c", filename)

		if output, err := cmd.Output(); err != nil {
			slog.Warn("Adding extra VFP rules", "error", err)
			cmd.Wait()
			slog.Warn("Adding extra VFP rules, will retry")
			execution = false
		} else {
			slog.Debug("Adding extra VFP rules", "output", string(output))
			cmd.Wait()
		}

		// check if rules are applied
		bRules, err := areVfpRulesApplied(portid, vfpRoutes)

		slog.Debug("Vfp rules are all applied", "result", bRules)

		if err != nil {
			slog.Warn("Checking if rules are applied", "error", err)
			execution = false
		} else if !bRules {
			slog.Warn("Rules are not applied, will retry")
			execution = false
		} else if bRules {
			slog.Debug("Rules are applied")
			execution = true
		}

		time.Sleep(1000 * time.Millisecond)
	}
	// check if port was found
	if !execution {
		slog.Error("failed to execute file", "file-name", filename)

		return fmt.Errorf("[cni-net] failed to execute file: %s", filename)
	}

	slog.Debug("Command file was executed successfully", "file-name", filename)

	return nil
}

func areVfpRulesApplied(portid string, vfpRoutes *VfpRoutes) (bool, error) {
	// loop through all the rules and check if they are applied
	for _, vfpRoute := range vfpRoutes.Routes {
		// check if the rule is applied
		cmd := exec.Command("vfpctrl", "/port", portid, "/layer", "VNET_PA_ROUTE_LAYER", "/group", "VNET_GROUP_PA_ROUTE_IPV4_OUT", "/list-rule")
		output, err := cmd.Output()
		if err != nil {
			slog.Error("failed to get rules", "error", err)
			return false, err
		}

		// check if the rule is in the output
		if strings.Contains(string(output), vfpRoute.Name) {
			slog.Info("Rule was applied", "name", vfpRoute.Name)
		} else {
			slog.Info("Rule was not applied", "name", vfpRoute.Name)
			return false, nil
		}
	}
	return true, nil
}
