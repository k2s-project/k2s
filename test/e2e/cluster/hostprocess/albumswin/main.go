// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	// Sub Repositories

	"github.com/gin-gonic/gin"

	"github.com/k2s-project/k2s/internal/logging"
)

// album represents data about a record album.
type album struct {
	ID     string  `json:"id"`
	Title  string  `json:"title"`
	Artist string  `json:"artist"`
	Price  float64 `json:"price"`
}

// albums slice to seed record album data.
var albums = []album{
	{ID: "1", Title: "Pawn Hearts", Artist: "Van der Graaf Generator", Price: 26.99},
	{ID: "2", Title: "A Passion Play", Artist: "Jethro Tull", Price: 17.99},
	{ID: "3", Title: "Tales from Topographic Oceans", Artist: "Yes", Price: 32.99},
}

// Health state tracking
var (
	startedAt        time.Time // set in main() to capture actual process resume time
	readinessFlag    int32     // 0 = not ready, 1 = ready
	livenessFailures int32     // increment on simulated failures (for future extension)
)

// Mark application ready when main finishes initial setup.
func markReady() { atomic.StoreInt32(&readinessFlag, 1) }

// startupHealth returns 200 only after minimal startup time threshold has elapsed.
// Distinct name: startupHealth.
func startupHealth(c *gin.Context) {
	// Allow a small grace period (e.g., 3s) for early init before reporting healthy.
	if time.Since(startedAt) < 3*time.Second {
		c.JSON(http.StatusServiceUnavailable, gin.H{"status": "starting"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "started", "uptimeSeconds": int(time.Since(startedAt).Seconds())})
}

// readinessHealth returns 200 only once readinessFlag is set.
// Distinct name: readinessHealth.
func readinessHealth(c *gin.Context) {
	if atomic.LoadInt32(&readinessFlag) != 1 {
		c.JSON(http.StatusServiceUnavailable, gin.H{"status": "not-ready"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ready"})
}

// livenessHealth returns 200 unless livenessFailures exceeds a threshold.
// Distinct name: livenessHealth.
func livenessHealth(c *gin.Context) {
	if atomic.LoadInt32(&livenessFailures) > 1000 { // placeholder threshold
		c.JSON(http.StatusInternalServerError, gin.H{"status": "unhealthy"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "alive"})
}

var (
	kernel32         = syscall.NewLazyDLL("kernel32.dll")
	procVirtualAlloc = kernel32.NewProc("VirtualAlloc")
	procVirtualLock  = kernel32.NewProc("VirtualLock")
)

const (
	MEM_COMMIT     = 0x1000
	MEM_RESERVE    = 0x2000
	PAGE_READWRITE = 0x04
)

func allocatePhysicalMemory(gb int) ([]byte, error) {
	// 1 GB = 1024 * 1024 * 1024 bytes
	size := gb * 1024 * 1024 * 1024

	// Allocate memory using VirtualAlloc
	addr, _, err := procVirtualAlloc.Call(
		0,
		uintptr(size),
		MEM_RESERVE|MEM_COMMIT,
		PAGE_READWRITE,
	)
	if addr == 0 {
		return nil, fmt.Errorf("VirtualAlloc failed: %v", err)
	}

	// Convert the pointer to a slice safely
	mem := unsafe.Slice((*byte)(unsafe.Pointer(addr)), size)
	return mem, nil
}

var (
	netioapi                          = syscall.NewLazyDLL("iphlpapi.dll")
	procSetCurrentThreadCompartmentId = netioapi.NewProc("SetCurrentThreadCompartmentId")
)

func SetCurrentThreadCompartmentId(compartmentId uint32) error {
	ret, _, err := procSetCurrentThreadCompartmentId.Call(uintptr(compartmentId))
	if ret != 0 {
		return err
	}
	return nil
}

// hasNonLoopbackIP returns true if any non-loopback interface has at least one IP address.
func hasNonLoopbackIP() bool {
	interfaces, err := net.Interfaces()
	if err != nil {
		return false
	}
	for _, i := range interfaces {
		if i.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := i.Addrs()
		if err != nil {
			continue
		}
		if len(addrs) > 0 {
			return true
		}
	}
	return false
}

func DumpNetworkInterfaces() {
	// Poll until a non-loopback interface has an IP address assigned.
	// After a compartment switch the vEthernet adapter may be visible before
	// the CNI has finished assigning its IP, so we retry for up to 30 s.
	const maxWait = 30 * time.Second
	const pollInterval = 2 * time.Second
	deadline := time.Now().Add(maxWait)
	for !hasNonLoopbackIP() && time.Now().Before(deadline) {
		fmt.Printf("Waiting for non-loopback IP (retrying for up to %s)...\n", time.Until(deadline).Truncate(time.Second))
		time.Sleep(pollInterval)
	}

	// Get a list of all network interfaces
	interfaces, err := net.Interfaces()
	if err != nil {
		log.Fatalf("Failed to get network interfaces: %v", err)
	}

	fmt.Println("Network Interfaces:")
	fmt.Println("-------------------")

	if len(interfaces) == 0 {
		fmt.Println("No network interfaces found.")
		return
	}

	// Iterate over each interface
	for _, i := range interfaces {
		fmt.Printf("Name: %v\n", i.Name)
		fmt.Printf("  Hardware Address (MAC): %v\n", i.HardwareAddr)
		fmt.Printf("  Flags: %v\n", i.Flags.String())
		fmt.Printf("  MTU: %v\n", i.MTU)

		// Get the addresses associated with the interface
		addrs, err := i.Addrs()
		if err != nil {
			log.Printf("  Failed to get addresses for %v: %v\n", i.Name, err)
			continue
		}

		fmt.Println("  IP Addresses:")
		if len(addrs) == 0 {
			fmt.Println("    No IP addresses found for this interface.")
		} else {
			for _, addr := range addrs {
				var ip net.IP
				switch v := addr.(type) {
				case *net.IPNet:
					ip = v.IP
				case *net.IPAddr:
					ip = v.IP
				}
				if ip == nil {
					continue
				}
				fmt.Printf("    - %s\n", ip.String())
			}
		}
		fmt.Println("-------------------")
	}
}

func main() {
	// Capture actual process start time here (not at package init) because
	// cplauncher creates this process suspended — package-level time.Now()
	// fires while still suspended, making the startup grace period a no-op.
	startedAt = time.Now()

	resource, found := os.LookupEnv("RESOURCE")
	if !found {
		resource = "albums-win"
	}
	memoryinGB, found := os.LookupEnv("MEMORY-GB")
	if !found {
		memoryinGB = "0"
	}

	// convert from string to int
	gb, err := strconv.Atoi(memoryinGB)
	if err != nil {
		fmt.Println("Error converting memory in GB to int:", err)
		gb = 0
	}

	// allocate memory GBs in RAM if memory is bigger than 0
	memory := make([]byte, 10)
	if gb > 0 {
		// allocate memory in RAM
		memory, err = allocatePhysicalMemory(gb)
		if err != nil {
			fmt.Println("Error:", err)
			return
		}

		// set the memory content to a fixed value
		for i := 0; i < len(memory); i++ {
			memory[i] = 0x41
		}
	}

	// get environment variables for bind address and port
	bindAddress := os.Getenv("BIND_ADDRESS")
	if bindAddress == "" {
		bindAddress = "0.0.0.0" // default address
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080" // default port
	}

	// Dedicated health port (served separately so it can be excluded from Linkerd interception).
	// Environment variable name: HEALTH_PORT (defaults to 8081). Optionally HEALTH_BIND_ADDRESS overrides BIND_ADDRESS.
	healthBindAddress := os.Getenv("HEALTH_BIND_ADDRESS")
	if healthBindAddress == "" {
		healthBindAddress = bindAddress
	}
	healthPort := os.Getenv("HEALTH_PORT")
	if healthPort == "" {
		healthPort = "8081"
	}

	// get environment variables for bind address and port
	compartmentId := os.Getenv("COMPARTMENT_ID_ATTACH")
	// Set default values if environment variables are not set
	if compartmentId != "" {
		num, err := strconv.Atoi(compartmentId)
		if err == nil {
			// Pin goroutine to this OS thread — compartment IDs are per-thread.
			runtime.LockOSThread()
			fmt.Println("Using compartment id: ", compartmentId)
			err := SetCurrentThreadCompartmentId(uint32(num))
			if err != nil {
				fmt.Println("Failed to set compartment ID: %v", err)
			}
		}
	}

	// After switching compartment, dump the network interfaces for diagnostics.
	DumpNetworkInterfaces()

	// create the full address string
	addr := fmt.Sprintf("%s:%s", bindAddress, port)

	// Configure Gin logging with timestamps for both debug route registration and requests.
	// 1. Override route debug printing without double timestamp (custom formatter already adds one).
	// Disable default logger prefix timestamps.
	log.SetFlags(0)
	gin.DebugPrintRouteFunc = func(httpMethod, absolutePath, handlerName string, nuHandlers int) {
		// Single RFC3339 timestamp for route registration lines.
		fmt.Printf("[GIN-debug] %s %s %-30s --> %s (%d handlers)\n", time.Now().Format(time.RFC3339), httpMethod, absolutePath, handlerName, nuHandlers)
	}

	// 2. Create a custom logger formatter for request logs to ensure consistent timestamping.
	customLogger := gin.LoggerWithFormatter(func(param gin.LogFormatterParams) string {
		// param.TimeStamp is the time the request was logged.
		return fmt.Sprintf("[GIN] %s | %3d | %13v | %15s | %-7s %s\n",
			param.TimeStamp.Format(time.RFC3339),
			param.StatusCode,
			param.Latency,
			param.ClientIP,
			param.Method,
			param.Path,
		)
	})

	// 3. Optionally log to both stdout and a file under the resolved K2s log root (if writable).
	logFilePath := filepath.Join(logging.RootLogDir(), "albumswin", "gin.log")
	_ = os.MkdirAll(filepath.Dir(logFilePath), 0o755)
	if f, err := os.OpenFile(logFilePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644); err == nil {
		gin.DefaultWriter = io.MultiWriter(f, os.Stdout)
	} else {
		// Fallback: keep default stdout only.
		log.Printf("[GIN-debug] could not open log file %s: %v", logFilePath, err)
	}

	router := gin.New()
	router.SetTrustedProxies(nil)
	router.Use(customLogger, gin.Recovery())

	// Duplicate health endpoints on primary app port as well (in addition to dedicated health port)
	// so they remain reachable via standard service port when sidecar interception is desired.
	router.GET("/health/startup", startupHealth)
	router.GET("/health/readiness", readinessHealth)
	router.GET("/health/liveness", livenessHealth)

	// Health endpoints are moved to a dedicated router on a separate port so probes can bypass the mesh proxy via port skipping.
	healthRouter := gin.New()
	healthRouter.SetTrustedProxies(nil)
	healthRouter.Use(customLogger, gin.Recovery())
	healthRouter.GET("/health/startup", startupHealth)
	healthRouter.GET("/health/readiness", readinessHealth)
	healthRouter.GET("/health/liveness", livenessHealth)

	// Launch health server concurrently.
	go func() {
		// Pin goroutine to this OS thread — compartment IDs are per-thread.
		runtime.LockOSThread()
		// Switch to the anchor pod's network compartment so the health server
		// binds to the same compartment as the main app server.  Both servers
		// are only reachable via the anchor pod's IP (through kube-proxy /
		// Service ClusterIP), NOT from localhost on the host.
		if compartmentId != "" {
			num, err := strconv.Atoi(compartmentId)
			if err == nil {
				fmt.Println("Using compartment id: ", compartmentId)
				err := SetCurrentThreadCompartmentId(uint32(num))
				if err != nil {
					fmt.Println("Failed to set compartment ID: %v", err)
				}
			}
		}

		healthAddr := fmt.Sprintf("%s:%s", healthBindAddress, healthPort)
		log.Printf("[health] listening on %s", healthAddr)
		if err := healthRouter.Run(healthAddr); err != nil {
			log.Printf("[health] server error: %v", err)
		}
	}()

	// Mark app ready after routes & initial network dumps configured.
	markReady()
	router.GET("/"+resource, getAlbums)
	router.GET("/"+resource+"/:id", getAlbumByID)
	router.POST("/"+resource, postAlbums)
	log.Printf("[app] listening on %s", addr)
	router.Run(addr)
}

// getAlbums responds with the list of all albums as JSON.
func getAlbums(c *gin.Context) {
	c.IndentedJSON(http.StatusOK, albums)
}

// postAlbums adds an album from JSON received in the request body.
func postAlbums(c *gin.Context) {
	var newAlbum album

	// Call BindJSON to bind the received JSON to
	// newAlbum.
	if err := c.BindJSON(&newAlbum); err != nil {
		return
	}

	// Add the new album to the slice.
	albums = append(albums, newAlbum)
	c.IndentedJSON(http.StatusCreated, newAlbum)
}

// getAlbumByID locates the album whose ID value matches the id
// parameter sent by the client, then returns that album as a response.
func getAlbumByID(c *gin.Context) {
	id := c.Param("id")

	// Loop through the list of albums, looking for
	// an album whose ID value matches the parameter.
	for _, a := range albums {
		if a.ID == id {
			c.IndentedJSON(http.StatusOK, a)
			return
		}
	}
	c.IndentedJSON(http.StatusNotFound, gin.H{"message": "album not found"})
}
