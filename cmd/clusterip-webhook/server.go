// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"os"
	"time"
)

const (
	defaultHealthAddr   = ":8080"
	defaultClientCAFile = "/client-ca/ca.crt"
)

// loadClientCAs reads the CA certificates that the client certificate of the
// kube-apiserver must chain to. The file must contain nothing but currently
// valid CA certificates, so that the admission listener never starts with a
// missing, empty or unintended trust anchor.
func loadClientCAs(path string) (*x509.CertPool, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read client CA file: %w", err)
	}

	pool := x509.NewCertPool()
	now := time.Now()
	found := false
	for {
		var block *pem.Block
		block, data = pem.Decode(data)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			return nil, fmt.Errorf("client CA file %q contains a %q block, only certificates are allowed", path, block.Type)
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("parse certificate in client CA file %q: %w", path, err)
		}
		if !cert.BasicConstraintsValid || !cert.IsCA {
			return nil, fmt.Errorf("certificate %q in client CA file %q is not a CA certificate", cert.Subject, path)
		}
		if now.Before(cert.NotBefore) || now.After(cert.NotAfter) {
			return nil, fmt.Errorf("CA certificate %q in client CA file %q is only valid from %s to %s",
				cert.Subject, path, cert.NotBefore.Format(time.RFC3339), cert.NotAfter.Format(time.RFC3339))
		}
		pool.AddCert(cert)
		found = true
	}
	if !found {
		return nil, fmt.Errorf("client CA file %q contains no certificate", path)
	}

	return pool, nil
}

// newAdmissionServer returns the server for the admission endpoints. Every
// connection must present a client certificate that chains to clientCAs, which
// only the kube-apiserver holds. The TLS handshake fails otherwise, so no
// request of an unauthenticated caller reaches a handler.
func newAdmissionServer(addr string, handler *WebhookHandler, serverCert tls.Certificate, clientCAs *x509.CertPool) (*http.Server, error) {
	// Without a pool crypto/tls verifies client certificates against the system
	// roots, which would accept certificates issued by any public CA.
	if clientCAs == nil {
		return nil, errors.New("client CA pool is required")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", handler.handleMutate)
	mux.HandleFunc("/mutate-workload", handler.handleMutateWorkload)

	return &http.Server{
		Addr:    addr,
		Handler: mux,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{serverCert},
			MinVersion:   tls.VersionTLS12,
			ClientAuth:   tls.RequireAndVerifyClientCert,
			ClientCAs:    clientCAs,
		},
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}, nil
}

// newHealthServer returns the plain HTTP server for the kubelet probes, which
// cannot present a client certificate. It must never serve an admission endpoint.
func newHealthServer(addr string) *http.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	return &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}
}
