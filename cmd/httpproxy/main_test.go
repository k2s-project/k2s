// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Main Proxy Runner Tests", func() {
	BeforeEach(func() {
		resetListenerState()
		DeferCleanup(resetListenerState)
	})

	Describe("runProxy", func() {
		When("cfg is nil", func() {
			It("returns an error", func() {
				listenCalled := false
				err := runProxy(
					nil,
					func(network, address string) (net.Listener, error) {
						listenCalled = true
						return nil, nil
					},
					nil,
				)

				Expect(err).To(HaveOccurred())
				Expect(listenCalled).To(BeFalse())
			})
		})

		When("no allowed CIDR is configured", func() {
			It("fails closed before calling listen", func() {
				cfg := newTestProxyConfig("127.0.0.1:0")
				listenCalled := false

				err := runProxy(
					cfg,
					func(network, address string) (net.Listener, error) {
						listenCalled = true
						return nil, nil
					},
					func(l net.Listener, h http.Handler) error {
						return nil
					},
				)

				Expect(err).To(MatchError(ContainSubstring("no allowed CIDR configured")))
				Expect(listenCalled).To(BeFalse())
			})
		})

		When("an allowed CIDR is invalid", func() {
			It("fails closed before calling listen", func() {
				cfg := newTestProxyConfig("127.0.0.1:0", "not-a-cidr")
				listenCalled := false

				err := runProxy(
					cfg,
					func(network, address string) (net.Listener, error) {
						listenCalled = true
						return nil, nil
					},
					func(l net.Listener, h http.Handler) error {
						return nil
					},
				)

				Expect(err).To(MatchError(ContainSubstring("invalid allowed CIDR")))
				Expect(listenCalled).To(BeFalse())
			})
		})

		When("listen fails", func() {
			It("returns an error instead of succeeding", func() {
				cfg := newTestProxyConfig("127.0.0.1:8181", "127.0.0.0/8")
				listenErr := errors.New("address already in use")
				serveCalled := false

				err := runProxy(
					cfg,
					func(network, address string) (net.Listener, error) {
						return nil, listenErr
					},
					func(l net.Listener, h http.Handler) error {
						serveCalled = true
						return nil
					},
				)

				Expect(err).To(MatchError(listenErr))
				Expect(serveCalled).To(BeFalse())
			})
		})

		When("serve returns a genuine error", func() {
			It("propagates the error and closes the listener", func() {
				cfg := newTestProxyConfig("127.0.0.1:0", "127.0.0.0/8")
				serveErr := errors.New("unexpected accept failure")
				var boundListener net.Listener

				err := runProxy(
					cfg,
					func(network, address string) (net.Listener, error) {
						l, listenErr := net.Listen(network, address)
						boundListener = l
						return l, listenErr
					},
					func(l net.Listener, h http.Handler) error {
						return serveErr
					},
				)

				Expect(err).To(MatchError(serveErr))
				Expect(boundListener).ToNot(BeNil())
				_, acceptErr := boundListener.Accept()
				Expect(acceptErr).To(MatchError(net.ErrClosed))
			})
		})

		When("serve returns http.ErrServerClosed", func() {
			It("treats it as a clean shutdown", func() {
				cfg := newTestProxyConfig("127.0.0.1:0", "127.0.0.0/8")

				err := runProxy(
					cfg,
					net.Listen,
					func(l net.Listener, h http.Handler) error {
						return http.ErrServerClosed
					},
				)

				Expect(err).ToNot(HaveOccurred())
			})
		})

		When("shutdown is requested before setListener runs", func() {
			It("closes the newly bound listener and exits cleanly without calling serve", func() {
				cfg := newTestProxyConfig("127.0.0.1:0", "127.0.0.0/8")
				var boundListener net.Listener
				serveCalled := false

				Expect(closeListener()).To(Succeed())

				err := runProxy(
					cfg,
					func(network, address string) (net.Listener, error) {
						l, listenErr := net.Listen(network, address)
						boundListener = l
						return l, listenErr
					},
					func(l net.Listener, h http.Handler) error {
						serveCalled = true
						return nil
					},
				)

				Expect(err).ToNot(HaveOccurred())
				Expect(serveCalled).To(BeFalse())
				Expect(boundListener).ToNot(BeNil())
				_, acceptErr := boundListener.Accept()
				Expect(acceptErr).To(MatchError(net.ErrClosed))
			})
		})

		When("proxy binds cleanly on an ephemeral port and shuts down via closeListener", func() {
			It("accepts TCP connections and exits cleanly when closeListener is called", func() {
				cfg := newTestProxyConfig("127.0.0.1:0", "127.0.0.0/8")
				addrCh := make(chan string, 1)
				errCh := make(chan error, 1)

				go func() {
					errCh <- runProxy(
						cfg,
						net.Listen,
						func(l net.Listener, h http.Handler) error {
							addrCh <- l.Addr().String()
							return http.Serve(l, h)
						},
					)
				}()

				var boundAddr string
				Eventually(addrCh, 3*time.Second).Should(Receive(&boundAddr))

				conn, err := net.DialTimeout("tcp", boundAddr, 2*time.Second)
				Expect(err).ToNot(HaveOccurred())
				_ = conn.Close()

				Expect(closeListener()).To(Succeed())
				Eventually(errCh, 3*time.Second).Should(Receive(BeNil()))
			})
		})
	})

	Describe("setListener and closeListener", func() {
		It("safely handles concurrent closeListener calls", func() {
			l, err := net.Listen("tcp", "127.0.0.1:0")
			Expect(err).ToNot(HaveOccurred())
			Expect(setListener(l)).To(BeTrue())

			var closeCount atomic.Int32
			var wg sync.WaitGroup
			for range 8 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					if err := closeListener(); err == nil {
						closeCount.Add(1)
					}
				}()
			}
			wg.Wait()

			Expect(closeCount.Load()).To(Equal(int32(8)))
			_, acceptErr := l.Accept()
			Expect(acceptErr).To(MatchError(net.ErrClosed))
			Expect(closeListener()).To(Succeed())
		})

		It("immediately closes a listener passed to setListener after closeListener", func() {
			Expect(closeListener()).To(Succeed())

			l, err := net.Listen("tcp", "127.0.0.1:0")
			Expect(err).ToNot(HaveOccurred())
			Expect(setListener(l)).To(BeFalse())

			_, acceptErr := l.Accept()
			Expect(acceptErr).To(MatchError(net.ErrClosed))
		})
	})
})

func newTestProxyConfig(listenAddr string, cidrs ...string) *proxyConfig {
	verbose := false
	forwardProxy := ""
	return newProxyConfig(&verbose, &listenAddr, &forwardProxy, networkCIDRs(cidrs))
}
