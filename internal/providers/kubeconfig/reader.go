// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package kubeconfig

import (
	"fmt"
	"log/slog"

	"github.com/samber/lo"
	"github.com/k2s-project/k2s/internal/yaml"
)

type Kubeconfig struct {
	Clusters       []Cluster `yaml:"clusters"`
	Users          []User    `yaml:"users"`
	Contexts       []Context `yaml:"contexts"`
	CurrentContext string    `yaml:"current-context"`
}

type Cluster struct {
	Name    string         `yaml:"name"`
	Details ClusterDetails `yaml:"cluster"`
}

type ClusterDetails struct {
	Cert   string `yaml:"certificate-authority-data"`
	Server string `yaml:"server"`
}

type User struct {
	Name    string      `yaml:"name"`
	Details UserDetails `yaml:"user"`
}

type UserDetails struct {
	Cert string `yaml:"client-certificate-data"`
	Key  string `yaml:"client-key-data"`
}

type Context struct {
	Name    string         `yaml:"name"`
	Details ContextDetails `yaml:"context"`
}

type ContextDetails struct {
	Cluster string `yaml:"cluster"`
	User    string `yaml:"user"`
}

const DefaultFileName = "config"

func FromFile(path string) (*Kubeconfig, error) {
	slog.Debug("Reading kubeconfig from file", "path", path)

	config, err := yaml.FromFile[Kubeconfig](path)
	if err != nil {
		return nil, fmt.Errorf("could not read kubeconfig from '%s': %w", path, err)
	}
	return config, nil
}

func (k *Kubeconfig) FindCluster(name string) (*Cluster, error) {
	cluster, found := lo.Find(k.Clusters, func(c Cluster) bool {
		return c.Name == name
	})
	if !found {
		return nil, fmt.Errorf("cluster '%s' not found in config", name)
	}
	return &cluster, nil
}

func (k *Kubeconfig) FindUser(name string) (*User, error) {
	user, found := lo.Find(k.Users, func(c User) bool {
		return c.Name == name
	})
	if !found {
		return nil, fmt.Errorf("user '%s' not found in config", name)
	}
	return &user, nil
}

func (k *Kubeconfig) FindContextByCluster(clusterName string) (*Context, error) {
	context, found := lo.Find(k.Contexts, func(c Context) bool {
		return c.Details.Cluster == clusterName
	})
	if !found {
		return nil, fmt.Errorf("context for cluster '%s' not found in config", clusterName)
	}
	return &context, nil
}

func (k *Kubeconfig) FindK8sApiCredentials(contextName string) (*Cluster, *User, error) {
	context, found := lo.Find(k.Contexts, func(c Context) bool {
		return c.Name == contextName
	})
	if !found {
		return nil, nil, fmt.Errorf("context '%s' not found in config", contextName)
	}

	user, found := lo.Find(k.Users, func(u User) bool {
		return u.Name == context.Details.User
	})
	if !found {
		return nil, nil, fmt.Errorf("user '%s' not found in kubeconfig", context.Details.User)
	}

	cluster, found := lo.Find(k.Clusters, func(c Cluster) bool {
		return c.Name == context.Details.Cluster
	})
	if !found {
		return nil, nil, fmt.Errorf("cluster '%s' not found in kubeconfig", context.Details.Cluster)
	}
	return &cluster, &user, nil
}
