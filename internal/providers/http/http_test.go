// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package http_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"testing"

	h "net/http"

	"github.com/gin-gonic/gin"
	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/providers/http"
)

type ping struct {
	Msg string `json:"msg"`
}

type pong struct {
	ping
}

func TestHttpPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "http pkg Tests", Label("ci", "internal", "http"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("http pkg", func() {
	Describe("Post", func() {
		When("marshalling payload failed", Label("unit"), func() {
			It("returns error", func() {
				invalidPayload := func() {}

				sut := http.NewRestClient()

				err := sut.Post("", invalidPayload, nil)

				var jsonErr *json.UnsupportedTypeError
				Expect(errors.As(err, &jsonErr)).To(BeTrue())
			})
		})

		When("posting payload failed", Label("unit"), func() {
			It("returns error", func() {
				const invalidUrl = ""

				sut := http.NewRestClient()

				err := sut.Post(invalidUrl, "", nil)

				Expect(err).To(MatchError(ContainSubstring("failed to post json")))
			})
		})

		When("post succeeds", Label("integration"), func() {
			const serverAddr = ":54321"
			const host = "http://localhost" + serverAddr
			var url string
			var endpoint string

			BeforeEach(func(ctx context.Context) {
				endpoint = fmt.Sprintf("/%d", GinkgoRandomSeed())
				url = host + endpoint

				GinkgoWriter.Println("Generated url", url)

				gin.SetMode(gin.ReleaseMode)
			})

			When("web server returns unexpected http status code", func() {
				BeforeEach(func(ctx context.Context) {
					router := gin.Default()
					router.POST(endpoint, func(c *gin.Context) {
						c.IndentedJSON(h.StatusOK, nil)
					})

					server := &h.Server{
						Addr:    serverAddr,
						Handler: router.Handler(),
					}

					GinkgoWriter.Println("Starting web server at", serverAddr)

					go func() {
						defer GinkgoRecover()

						Expect(server.ListenAndServe()).To(MatchError(h.ErrServerClosed))
					}()

					DeferCleanup(func() {
						GinkgoWriter.Println("Stopping web server at", server.Addr)
						Expect(server.Shutdown(ctx)).To(Succeed())
					})
				})

				It("returns error", func() {
					sut := http.NewRestClient()

					var pong pong

					err := sut.Post(url, nil, &pong)

					Expect(err).To(MatchError(SatisfyAll(
						ContainSubstring("unexpected http status"),
						ContainSubstring("expected '201'"),
						ContainSubstring("got '200'"),
					)))
				})
			})

			When("web server returns invalid JSON", func() {
				BeforeEach(func(ctx context.Context) {
					router := gin.Default()
					router.POST(endpoint, func(c *gin.Context) {
						c.IndentedJSON(h.StatusCreated, "invalid")
					})

					server := &h.Server{
						Addr:    serverAddr,
						Handler: router.Handler(),
					}

					GinkgoWriter.Println("Starting web server at", serverAddr)

					go func() {
						defer GinkgoRecover()

						Expect(server.ListenAndServe()).To(MatchError(h.ErrServerClosed))
					}()

					DeferCleanup(func() {
						GinkgoWriter.Println("Stopping web server at", server.Addr)
						Expect(server.Shutdown(ctx)).To(Succeed())
					})
				})

				It("returns error", func() {
					sut := http.NewRestClient()

					var pong pong

					err := sut.Post(url, nil, &pong)

					var jsonErr *json.UnmarshalTypeError
					Expect(errors.As(err, &jsonErr)).To(BeTrue())
				})
			})

			When("web server returns valid JSON", func() {
				BeforeEach(func(ctx context.Context) {
					router := gin.Default()
					router.POST(endpoint, func(c *gin.Context) {
						var ping ping
						Expect(c.BindJSON(&ping)).To(Succeed())
						c.IndentedJSON(h.StatusCreated, pong{ping: ping})
					})

					server := &h.Server{
						Addr:    serverAddr,
						Handler: router.Handler(),
					}

					GinkgoWriter.Println("Starting web server at", serverAddr)

					go func() {
						defer GinkgoRecover()

						Expect(server.ListenAndServe()).To(MatchError(h.ErrServerClosed))
					}()

					DeferCleanup(func() {
						GinkgoWriter.Println("Stopping web server at", server.Addr)
						Expect(server.Shutdown(ctx)).To(Succeed())
					})
				})

				It("unmarshalls the result correctly", func() {
					ping := ping{Msg: "hello there"}

					sut := http.NewRestClient()

					var pong pong

					err := sut.Post(url, ping, &pong)

					Expect(err).ToNot(HaveOccurred())
					Expect(pong.Msg).To(Equal(ping.Msg))
				})
			})
		})
	})
})
