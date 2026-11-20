// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package http

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
)

type restClient struct {
	httpClient *http.Client
}

func NewRestClient() *restClient {
	return &restClient{httpClient: &http.Client{}}
}

func (rc *restClient) SetTLSConfig(caCert, userCert, userKey []byte) error {
	certPool := x509.NewCertPool()
	if !certPool.AppendCertsFromPEM(caCert) {
		return errors.New("failed to parse CA cert")
	}

	userCertKeyPair, err := tls.X509KeyPair(userCert, userKey)
	if err != nil {
		return fmt.Errorf("failed to create user cert/key pair: %w", err)
	}

	rc.httpClient.Transport = &http.Transport{
		TLSClientConfig: &tls.Config{
			RootCAs:      certPool,
			Certificates: []tls.Certificate{userCertKeyPair},
		},
	}
	return nil
}

// Post sends a POST request with the given payload to the specified URL and decodes the response into the provided result variable.
// It fails on http status codes other than 201 Created and returns an error if the request or response processing fails.
func (rc *restClient) Post(url string, payload any, result any) error {
	jsonBody, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("failed to marshal json payload: %w", err)
	}

	bodyReader := bytes.NewReader(jsonBody)
	response, err := rc.httpClient.Post(url, "application/json", bodyReader)
	if err != nil {
		return fmt.Errorf("failed to post json payload: %w", err)
	}

	defer func() {
		if err := response.Body.Close(); err != nil {
			slog.Error("failed to close http response body", "error", err)
		}
	}()

	if response.StatusCode != http.StatusCreated {
		return fmt.Errorf("unexpected http status code: expected '%d', but got '%d'", http.StatusCreated, response.StatusCode)
	}

	bytes, err := io.ReadAll(response.Body)
	if err != nil {
		return fmt.Errorf("failed to read response body: %w", err)
	}

	if err := json.Unmarshal(bytes, result); err != nil {
		return fmt.Errorf("failed to unmarshal json response into given result variable: %w", err)
	}
	return nil
}
