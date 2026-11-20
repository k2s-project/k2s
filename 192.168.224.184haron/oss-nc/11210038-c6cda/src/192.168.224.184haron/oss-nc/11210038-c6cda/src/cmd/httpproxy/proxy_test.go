// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Proxy Tests", func() {
	Describe("newProxyHttpHandler", func() {
		var (
			verbose      bool
			listenAddr   string
			forwardProxy string
		)

		newConfig := func(cidrs ...string) *proxyConfig {
			allowedCidrs := newNetworkCidrs()
			for _, cidr := range cidrs {
				Expect(allowedCidrs.Set(cidr)).To(Succeed())
			}
			return newProxyConfig(&verbose, &listenAddr, &forwardProxy, allowedCidrs)
		}

		// proxyGet sends a GET for target through a proxy server that serves handler on the loopback interface.
		proxyGet := func(handler http.Handler, target string) *http.Response {
			proxyServer := httptest.NewServer(handler)
			DeferCleanup(proxyServer.Close)

			proxyUrl, err := url.Parse(proxyServer.URL)
			Expect(err).ToNot(HaveOccurred())
			transport := &http.Transport{Proxy: http.ProxyURL(proxyUrl)}
			DeferCleanup(transport.CloseIdleConnections)

			resp, err := (&http.Client{Transport: transport}).Get(target)
			Expect(err).ToNot(HaveOccurred())
			DeferCleanup(resp.Body.Close)
			return resp
		}

		BeforeEach(func() {
			verbose = false
			listenAddr = ":8181"
			forwardProxy = ""
		})

		When("no allowed CIDR is configured", func() {
			It("returns an error instead of an unrestricted proxy", func() {
				handler, err := newProxyHttpHandler(newConfig())

				Expect(err).To(MatchError(ContainSubstring("no allowed CIDR configured")))
				Expect(handler).To(BeNil())
			})
		})

		When("an allowed CIDR is invalid", func() {
			It("returns an error", func() {
				config := newProxyConfig(&verbose, &listenAddr, &forwardProxy, networkCIDRs{"abc"})

				handler, err := newProxyHttpHandler(config)

				Expect(err).To(MatchError(ContainSubstring("invalid allowed CIDR")))
				Expect(handler).To(BeNil())
			})
		})

		When("the client is inside an allowed CIDR", func() {
			It("forwards the request", func() {
				backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
					_, _ = io.WriteString(w, "backend reached")
				}))
				DeferCleanup(backend.Close)

				handler, err := newProxyHttpHandler(newConfig("10.0.0.0/8", "127.0.0.0/8"))
				Expect(err).ToNot(HaveOccurred())

				resp := proxyGet(handler, backend.URL)

				Expect(resp.StatusCode).To(Equal(http.StatusOK))
				body, err := io.ReadAll(resp.Body)
				Expect(err).ToNot(HaveOccurred())
				Expect(string(body)).To(Equal("backend reached"))
			})
		})

		When("the client is outside all allowed CIDRs", func() {
			It("rejects the request without contacting the target", func() {
				var backendCalled atomic.Bool
				backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
					backendCalled.Store(true)
				}))
				DeferCleanup(backend.Close)

				handler, err := newProxyHttpHandler(newConfig("10.0.0.0/8"))
				Expect(err).ToNot(HaveOccurred())

				resp := proxyGet(handler, backend.URL)

				Expect(resp.StatusCode).To(Equal(http.StatusForbidden))
				Expect(backendCalled.Load()).To(BeFalse())
			})
		})
	})

	Describe("rejectProxyRequest", func() {
		var logOutput *bytes.Buffer

		BeforeEach(func() {
			logOutput = &bytes.Buffer{}
			previousLogger := slog.Default()
			slog.SetDefault(slog.New(slog.NewTextHandler(logOutput, nil)))
			DeferCleanup(slog.SetDefault, previousLogger)
		})

		It("denies the request and logs the rejected source", func() {
			req := httptest.NewRequest(http.MethodConnect, "172.19.1.1:4445", nil)
			req.RemoteAddr = "192.168.10.20:50123"
			recorder := httptest.NewRecorder()

			rejectProxyRequest(recorder, req)

			Expect(recorder.Code).To(Equal(http.StatusForbidden))
			Expect(logOutput.String()).To(ContainSubstring("Rejected proxy request from source outside the allowed CIDRs"))
			Expect(logOutput.String()).To(ContainSubstring("source=192.168.10.20:50123"))
			Expect(logOutput.String()).To(ContainSubstring("method=CONNECT"))
			Expect(logOutput.String()).To(ContainSubstring("host=172.19.1.1:4445"))
		})
	})
})
