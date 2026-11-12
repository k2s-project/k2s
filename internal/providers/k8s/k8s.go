// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package k8s

import (
	"fmt"
	"log/slog"
)

type restClient interface {
	SetTLSConfig(caCert, userCert, userKey []byte) error
	Post(url string, payload any, result any) error
}

type UserInfoAPI struct {
	restClient restClient
}

type SelfSubjectReview struct {
	Kind       string     `json:"kind"`
	ApiVersion string     `json:"apiVersion"`
	Metadata   Metadata   `json:"metadata"`
	Status     AuthStatus `json:"status"`
}

type Metadata struct {
	Timestamp *string `json:"creationTimestamp"`
}

type AuthStatus struct {
	UserInfo UserInfo `json:"userInfo"`
}

type UserInfo struct {
	Name   string   `json:"username"`
	Groups []string `json:"groups"`
}

const whoAmIRequestUrlRoute = "/apis/authentication.k8s.io/v1/selfsubjectreviews"

func NewUserInfoAPI(restClient restClient) *UserInfoAPI {
	return &UserInfoAPI{
		restClient: restClient,
	}
}

func (v *UserInfoAPI) FetchUserInfo(server string, caCert, userCert, userKey []byte) (*UserInfo, error) {
	slog.Debug("Fetching user info via Kubernetes API", "server", server)

	if err := v.restClient.SetTLSConfig(caCert, userCert, userKey); err != nil {
		return nil, fmt.Errorf("failed to set http client TLS config: %w", err)
	}

	request := newWhoAmIRequest()
	url := server + whoAmIRequestUrlRoute

	var response SelfSubjectReview
	if err := v.restClient.Post(url, request, &response); err != nil {
		return nil, fmt.Errorf("failed to POST who-am-I request to K8s API '%s': %w", url, err)
	}

	slog.Debug("User info fetched via Kubernetes API", "user-name", response.Status.UserInfo.Name, "server", server)
	return &response.Status.UserInfo, nil
}

func newWhoAmIRequest() *SelfSubjectReview {
	return &SelfSubjectReview{
		Kind:       "SelfSubjectReview",
		ApiVersion: "authentication.k8s.io/v1",
		Metadata:   Metadata{},
		Status:     AuthStatus{UserInfo: UserInfo{}},
	}
}
