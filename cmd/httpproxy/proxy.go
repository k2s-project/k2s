// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/cloudflare/cfssl/whitelist"
	"github.com/elazarl/goproxy"
)

func newProxyConfig(verbose *bool, listenAddress *string, forwardProxy *string, allowedCidrs networkCIDRs) *proxyConfig {
	return &proxyConfig{
		VerboseLogging: verbose,
		ListenAddress:  listenAddress,
		ForwardProxy:   forwardProxy,
		AllowedCidrs:   allowedCidrs,
	}
}

func configureForwardProxyInProxyHttpServer(proxy *goproxy.ProxyHttpServer, forwardProxy string) {
	// use the forward transparent proxy
	proxy.Tr.Proxy = func(req *http.Request) (*url.URL, error) {
		return url.Parse(forwardProxy)
	}
	// for SSL conection forwarding is needed
	proxy.ConnectDialWithReq = func(req *http.Request, network string, addr string) (net.Conn, error) {
		if !useProxy(canonicalAddr(req.URL), getenvEitherCase) {
			log.Printf("For request %s don't use proxy", req.URL.String())
			return net.Dial(network, addr)
		}
		log.Printf("For request %s use proxy", req.URL.String())
		return proxy.NewConnectDialToProxy(forwardProxy)(network, addr)
	}
}

func getListenInterfaceWhitelist(allowedNetInterfaces []*net.IPNet) *whitelist.BasicNet {
	wl := whitelist.NewBasicNet()
	for _, interf := range allowedNetInterfaces {
		wl.Add(interf)
	}
	return wl
}

// newProxyHttpHandler returns the proxy handler wrapped in a source address whitelist.
// It fails closed: without at least one allowed CIDR the proxy is not served at all,
// because an unrestricted forward proxy on the host would be reachable from every network.
func newProxyHttpHandler(proxyConfig *proxyConfig) (http.Handler, error) {
	if len(proxyConfig.AllowedCidrs) == 0 {
		return nil, errors.New("no allowed CIDR configured, refusing to serve the proxy without a source address whitelist")
	}
	allowedCidrs, err := proxyConfig.AllowedCidrs.ToIPNet()
	if err != nil {
		return nil, fmt.Errorf("invalid allowed CIDR: %w", err)
	}

	proxy := goproxy.NewProxyHttpServer()

	//if forward proxy is configured, use it
	if proxyConfig.ForwardProxy != nil && strings.TrimSpace(*proxyConfig.ForwardProxy) != "" {
		log.Printf("Starting httpproxy on %s with forward proxy: %s", *proxyConfig.ListenAddress, *proxyConfig.ForwardProxy)
		configureForwardProxyInProxyHttpServer(proxy, *proxyConfig.ForwardProxy)
	} else {
		log.Printf("Starting httpproxy on %s", *proxyConfig.ListenAddress)
	}

	proxy.Verbose = *proxyConfig.VerboseLogging

	//restrict http proxy access to clients from certain networks
	log.Printf("Http Proxy available for clients from networks: %s", proxyConfig.AllowedCidrs.String())
	listenInterfaceWhitelist := getListenInterfaceWhitelist(allowedCidrs)
	return whitelist.NewHandler(proxy, http.HandlerFunc(rejectProxyRequest), listenInterfaceWhitelist)
}

// rejectProxyRequest logs and denies a request whose source address is outside the allowed CIDRs.
func rejectProxyRequest(w http.ResponseWriter, req *http.Request) {
	slog.Warn("Rejected proxy request from source outside the allowed CIDRs", "source", req.RemoteAddr, "method", req.Method, "host", req.Host)
	status := http.StatusForbidden
	http.Error(w, http.StatusText(status), status)
}
