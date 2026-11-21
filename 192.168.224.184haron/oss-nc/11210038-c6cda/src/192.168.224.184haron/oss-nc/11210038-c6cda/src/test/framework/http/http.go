// SPDX-FileCopyrightText: © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package http

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/failsafe-go/failsafe-go"
	"github.com/failsafe-go/failsafe-go/failsafehttp"
	"github.com/failsafe-go/failsafe-go/retrypolicy"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
)

type ResilientHttpClient struct {
	executor failsafe.Executor[*http.Response]
	client   *http.Client
}

func NewResilientHttpClient(requestTimeout time.Duration, tlsConfig ...*tls.Config) *ResilientHttpClient {
	retryPolicy := buildRetryPolicy(requestTimeout)

	client := http.DefaultClient

	if len(tlsConfig) > 0 {
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.TLSClientConfig = tlsConfig[0]
		client.Transport = transport
	}

	return &ResilientHttpClient{
		executor: failsafe.With(retryPolicy),
		client:   client,
	}
}

// UseProxy configures the client to route requests through the specified proxy.
func (c *ResilientHttpClient) UseProxy(proxyAddress string) error {
	if strings.TrimSpace(proxyAddress) == "" {
		return nil
	}

	proxyURL, err := url.Parse(proxyAddress)
	if err != nil {
		return fmt.Errorf("parse proxy URL: %w", err)
	}

	transport, ok := c.client.Transport.(*http.Transport)
	if c.client.Transport == nil {
		transport = http.DefaultTransport.(*http.Transport)
		ok = true
	}
	if !ok {
		return fmt.Errorf("configure proxy for unsupported HTTP transport %T", c.client.Transport)
	}

	client := *c.client
	proxyTransport := transport.Clone()
	proxyTransport.Proxy = http.ProxyURL(proxyURL)
	client.Transport = proxyTransport
	c.client = &client

	return nil
}

// GetJson performs a GET request to the given URL, checks the payload for valid JSON and returns the payload as a byte array.
// It retries failed requests according to the retry policy.
func (c *ResilientHttpClient) GetJson(ctx context.Context, url string) ([]byte, error) {
	GinkgoWriter.Println("Calling http GET on <", url, ">")

	executor := c.executor.WithContext(ctx)

	request, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	failsafeRequest := failsafehttp.NewRequestWithExecutor(request, c.client, executor)

	response, err := failsafeRequest.Do()
	if err != nil {
		return nil, err
	}
	if !strings.Contains(response.Header.Get("Content-Type"), "application/json") {
		return nil, fmt.Errorf("unexpected content type <%s>", response.Header.Get("Content-Type"))
	}

	defer response.Body.Close()

	payload, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, err
	}
	if !json.Valid(payload) {
		return nil, fmt.Errorf("invalid JSON payload")
	}
	return payload, nil
}

// Get performs a GET request to the given URL and returns the payload as a byte array.
// It retries failed requests according to the retry policy.
func (c *ResilientHttpClient) Get(ctx context.Context, url string, headers ...map[string]string) ([]byte, error) {
	GinkgoWriter.Println("Calling http GET on <", url, ">")

	executor := c.executor.WithContext(ctx)

	request, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	if len(headers) > 0 {
		for key, value := range headers[0] {
			request.Header.Add(key, value)
		}
	}

	failsafeRequest := failsafehttp.NewRequestWithExecutor(request, c.client, executor)

	response, err := failsafeRequest.Do()
	if err != nil {
		return nil, err
	}

	defer response.Body.Close()

	return io.ReadAll(response.Body)
}

func buildRetryPolicy(requestTimeout time.Duration) retrypolicy.RetryPolicy[*http.Response] {
	return retrypolicy.NewBuilder[*http.Response]().
		WithBackoff(time.Second, time.Minute).
		WithJitterFactor(.25).
		WithMaxRetries(-1).
		WithMaxDuration(requestTimeout).
		OnRetry(func(e failsafe.ExecutionEvent[*http.Response]) {
			GinkgoWriter.Println("Last attempt failed with error: ", e.LastError())
			GinkgoWriter.Printf("This is retry no. %d, elapsed time so far: %v,  retrying\n", e.Retries(), e.ElapsedTime())
		}).
		HandleIf(func(response *http.Response, err error) bool {
			if err != nil {
				return true
			}
			if response != nil && response.StatusCode >= 400 {
				GinkgoWriter.Println("Failed due to status code: ", response.StatusCode)
				return true
			}
			return false
		}).
		Build()
}
