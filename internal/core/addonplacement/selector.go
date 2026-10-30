// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addonplacement

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/selection"
	"k8s.io/apimachinery/pkg/util/validation"
	kyaml "k8s.io/apimachinery/pkg/util/yaml"
	"sigs.k8s.io/yaml"
)

func ValidatePersistentVolumeHost(volumeData, nodeData []byte) error {
	var volume corev1.PersistentVolume
	var node corev1.Node
	if err := json.Unmarshal(bytes.TrimPrefix(volumeData, []byte{0xef, 0xbb, 0xbf}), &volume); err != nil {
		return fmt.Errorf("decode existing PV: %w", err)
	}
	if err := json.Unmarshal(bytes.TrimPrefix(nodeData, []byte{0xef, 0xbb, 0xbf}), &node); err != nil {
		return fmt.Errorf("decode storage host: %w", err)
	}
	if volume.Name == "" || node.Name == "" {
		return fmt.Errorf("existing PV and storage host must have names")
	}
	if volume.Spec.NodeAffinity == nil || volume.Spec.NodeAffinity.Required == nil {
		if volume.Spec.Local != nil {
			return fmt.Errorf("local PV %q has no required node affinity; cannot prove storage compatibility", volume.Name)
		}
		return nil
	}
	for _, term := range volume.Spec.NodeAffinity.Required.NodeSelectorTerms {
		if len(term.MatchExpressions) == 0 && len(term.MatchFields) == 0 {
			continue
		}
		compatible := true
		for _, expression := range term.MatchExpressions {
			operators := map[corev1.NodeSelectorOperator]selection.Operator{
				corev1.NodeSelectorOpIn: selection.In, corev1.NodeSelectorOpNotIn: selection.NotIn,
				corev1.NodeSelectorOpExists: selection.Exists, corev1.NodeSelectorOpDoesNotExist: selection.DoesNotExist,
				corev1.NodeSelectorOpGt: selection.GreaterThan, corev1.NodeSelectorOpLt: selection.LessThan,
			}
			operator, supported := operators[expression.Operator]
			if !supported {
				return fmt.Errorf("PV %q has unsupported affinity operator %q", volume.Name, expression.Operator)
			}
			requirement, err := labels.NewRequirement(expression.Key, operator, expression.Values)
			if err != nil {
				return fmt.Errorf("PV %q affinity: %w", volume.Name, err)
			}
			if !requirement.Matches(labels.Set(node.Labels)) {
				compatible = false
			}
		}
		for _, field := range term.MatchFields {
			if field.Key != "metadata.name" {
				return fmt.Errorf("PV %q has unsupported node field %q", volume.Name, field.Key)
			}
			allowed, err := affinityAllows(string(field.Operator), stringsToAny(field.Values), node.Name)
			if err != nil {
				return err
			}
			compatible = compatible && allowed
		}
		if compatible {
			return nil
		}
	}
	return fmt.Errorf("existing PV %q node affinity excludes storage host %q; placement does not migrate data", volume.Name, node.Name)
}

func stringsToAny(values []string) []any {
	converted := make([]any, len(values))
	for index, value := range values {
		converted[index] = value
	}
	return converted
}

// SupportsAddon reports addons with explicit pre-creation placement owners.
func SupportsAddon(addonName string) bool {
	switch addonName {
	case "metrics", "monitoring", "logging", "dashboard", "registry", "ingress":
		return true
	default:
		return false
	}
}

// ParseSelector parses comma-separated exact node selector requirements.
func ParseSelector(raw string) (map[string]string, error) {
	requirements := make(map[string]string)
	if raw == "" {
		return requirements, nil
	}
	if strings.TrimSpace(raw) == "" {
		return nil, fmt.Errorf("infrastructure node selector must not contain only whitespace")
	}

	for _, requirement := range strings.Split(raw, ",") {
		key, value, found := strings.Cut(strings.TrimSpace(requirement), "=")
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if !found || key == "" || strings.Contains(value, "=") {
			return nil, fmt.Errorf("invalid infrastructure node selector requirement %q: expected key=value", requirement)
		}
		if problems := validation.IsQualifiedName(key); len(problems) > 0 {
			return nil, fmt.Errorf("invalid infrastructure node selector key %q: %s", key, strings.Join(problems, "; "))
		}
		if problems := validation.IsValidLabelValue(value); len(problems) > 0 {
			return nil, fmt.Errorf("invalid infrastructure node selector value for key %q: %s", key, strings.Join(problems, "; "))
		}
		if _, exists := requirements[key]; exists {
			return nil, fmt.Errorf("infrastructure node selector contains duplicate key %q", key)
		}
		requirements[key] = value
	}

	return requirements, nil
}

func ResolveSelector(requested, saved string, found bool) (string, error) {
	requestedLabels, err := ParseSelector(requested)
	if err != nil {
		return "", err
	}
	if !found {
		return FormatSelector(requestedLabels), nil
	}
	savedLabels, err := ParseSelector(saved)
	if err != nil {
		return "", fmt.Errorf("invalid saved infrastructure selector: %w", err)
	}
	canonical := FormatSelector(savedLabels)
	if requested != "" && FormatSelector(requestedLabels) != canonical {
		return "", fmt.Errorf("infrastructure selector conflicts with saved selector %q; disable and re-enable the addon to change placement", saved)
	}
	return canonical, nil
}

// MergeSelector adds user requirements without weakening existing requirements.
func MergeSelector(existing map[string]string, raw string) (map[string]string, error) {
	requirements, err := ParseSelector(raw)
	if err != nil {
		return nil, err
	}

	merged := make(map[string]string, len(existing)+len(requirements))
	for key, value := range existing {
		merged[key] = value
	}
	for key, value := range requirements {
		if mandatory, exists := merged[key]; exists && mandatory != value {
			return nil, fmt.Errorf("infrastructure node selector conflicts with the addon's required node selector %q=%q (requested %q); choose a compatible value", key, mandatory, value)
		}
		merged[key] = value
	}

	return merged, nil
}

// FormatSelector returns a stable comma-separated representation.
func FormatSelector(selector map[string]string) string {
	keys := make([]string, 0, len(selector))
	for key := range selector {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, key+"="+selector[key])
	}
	return strings.Join(parts, ",")
}

func WorkloadSelectors(input []byte) ([]string, error) {
	decoder := kyaml.NewYAMLOrJSONDecoder(strings.NewReader(string(input)), 4096)
	selectors := []string{}
	for {
		var document map[string]any
		if err := decoder.Decode(&document); err != nil {
			if err == io.EOF {
				break
			}
			return nil, fmt.Errorf("decode workload selectors: %w", err)
		}
		kind, _ := document["kind"].(string)
		podSpec := workloadPodSpec(document, kind)
		if podSpec == nil {
			continue
		}
		selector, err := nodeSelector(podSpec)
		if err != nil {
			return nil, err
		}
		if len(selector) == 0 {
			return nil, fmt.Errorf("%s has no effective node selector", manifestIdentity(document))
		}
		selectors = append(selectors, FormatSelector(selector))
	}
	if len(selectors) == 0 {
		return nil, fmt.Errorf("rendered manifest contains no central workloads")
	}
	return selectors, nil
}

// RenderHelmValues merges placement into the Headlamp chart's owning values.
func RenderHelmValues(input []byte, rawSelector string) ([]byte, error) {
	if rawSelector == "" {
		return input, nil
	}
	requested, err := ParseSelector(rawSelector)
	if err != nil {
		return nil, err
	}
	var values map[string]any
	if err := yaml.Unmarshal(input, &values); err != nil {
		return nil, fmt.Errorf("decode chart values: %w", err)
	}
	if values == nil {
		return nil, fmt.Errorf("chart values must be a map")
	}
	existing, err := nodeSelector(values)
	if err != nil {
		return nil, err
	}
	merged, err := MergeSelector(existing, rawSelector)
	if err != nil {
		return nil, err
	}
	if err := validateNodeAffinity(values, requested); err != nil {
		return nil, err
	}
	values["nodeSelector"] = merged
	return yaml.Marshal(values)
}

// RenderManifestStream applies selector requirements to supported central workload templates.
// DaemonSets are left unchanged; custom-resource API groups are rejected unless explicitly supported.
func RenderManifestStream(input []byte, rawSelector string) ([]byte, int, error) {
	return RenderStorageManifestStream(input, rawSelector, "")
}

func RenderStorageManifestStream(input []byte, rawSelector, storageNode string) ([]byte, int, error) {
	requested, err := ParseSelector(rawSelector)
	if err != nil {
		return nil, 0, err
	}
	if len(requested) == 0 {
		return input, 0, nil
	}

	decoder := kyaml.NewYAMLOrJSONDecoder(strings.NewReader(string(input)), 4096)
	var rendered strings.Builder
	changed := 0
	for {
		var document map[string]any
		if err := decoder.Decode(&document); err != nil {
			if err == io.EOF {
				break
			}
			return nil, 0, fmt.Errorf("decode addon manifest: %w", err)
		}
		if len(document) == 0 {
			continue
		}

		kind, _ := document["kind"].(string)
		apiVersion, _ := document["apiVersion"].(string)
		if kind == "" || apiVersion == "" {
			return nil, 0, fmt.Errorf("manifest document must include apiVersion and kind; input may contain chart values or an unrendered template")
		}
		if err := validateResourceGroup(document); err != nil {
			return nil, 0, fmt.Errorf("%s: %w", manifestIdentity(document), err)
		}
		if kind == "PersistentVolume" && storageNode != "" {
			spec := nestedMap(document, "spec")
			affinity, _ := spec["nodeAffinity"].(map[string]any)
			if affinity != nil {
				required, _ := affinity["required"].(map[string]any)
				terms, _ := required["nodeSelectorTerms"].([]any)
				for _, term := range terms {
					expressions, _ := term.(map[string]any)["matchExpressions"].([]any)
					for _, entry := range expressions {
						expression := entry.(map[string]any)
						if expression["key"] != "kubernetes.io/hostname" {
							continue
						}
						values, _ := expression["values"].([]any)
						for index, value := range values {
							if value == "__STORAGE_NODE__" {
								values[index] = storageNode
							}
						}
					}
				}
				constraint := map[string]any{"affinity": map[string]any{"nodeAffinity": map[string]any{"requiredDuringSchedulingIgnoredDuringExecution": required}}}
				if err := validateNodeAffinity(constraint, requested); err != nil {
					return nil, 0, fmt.Errorf("%s storage topology: %w", manifestIdentity(document), err)
				}
			}
		}
		podSpec := workloadPodSpec(document, kind)
		if podSpec != nil {
			selector, err := nodeSelector(podSpec)
			if err != nil {
				return nil, 0, fmt.Errorf("%s: %w", manifestIdentity(document), err)
			}
			merged, err := MergeSelector(selector, rawSelector)
			if err != nil {
				return nil, 0, fmt.Errorf("%s: %w", manifestIdentity(document), err)
			}
			if err := validateNodeAffinity(podSpec, requested); err != nil {
				return nil, 0, fmt.Errorf("%s: %w", manifestIdentity(document), err)
			}
			podSpec["nodeSelector"] = merged
			changed++
		}

		encoded, err := yaml.Marshal(document)
		if err != nil {
			return nil, 0, fmt.Errorf("encode %s: %w", manifestIdentity(document), err)
		}
		if rendered.Len() > 0 {
			rendered.WriteString("---\n")
		}
		rendered.Write(encoded)
	}

	if changed == 0 {
		return nil, 0, fmt.Errorf("infrastructure node selector was provided, but the manifest stream contains no supported central workloads")
	}
	return []byte(rendered.String()), changed, nil
}

// RenderManifestDirectory renders direct YAML resources from a directory with a
// hard selector. Kustomize and Helm inputs require their own structured path.
func RenderManifestDirectory(manifestsDir, selector string) ([]byte, int, error) {
	if err := filepath.WalkDir(manifestsDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if isAddonSyncDirectory(manifestsDir, path) {
				return filepath.SkipDir
			}
			return nil
		}
		switch strings.ToLower(entry.Name()) {
		case "kustomization.yaml", "kustomization.yml":
			return fmt.Errorf("Kustomize input %q requires structured rendering and cannot be flattened safely with --infra-node-selector", path)
		case "chart.yaml":
			return fmt.Errorf("Helm chart %q requires chart-value integration and cannot be flattened safely with --infra-node-selector", path)
		default:
			return nil
		}
	}); err != nil {
		return nil, 0, err
	}

	var source strings.Builder
	err := filepath.WalkDir(manifestsDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if isAddonSyncDirectory(manifestsDir, path) {
				return filepath.SkipDir
			}
			return nil
		}
		name := strings.ToLower(entry.Name())
		if filepath.Ext(name) != ".yaml" && filepath.Ext(name) != ".yml" {
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		source.WriteString("---\n")
		source.Write(content)
		source.WriteByte('\n')
		return nil
	})
	if err != nil {
		return nil, 0, fmt.Errorf("read addon manifests: %w", err)
	}
	if source.Len() == 0 {
		return nil, 0, fmt.Errorf("no YAML manifests found")
	}

	rendered, changed, err := RenderManifestStream([]byte(source.String()), selector)
	return rendered, changed, err
}

// isAddonSyncDirectory reports the GitOps addon-sync infrastructure directory directly under the manifests root; it is not a central workload input.
func isAddonSyncDirectory(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel == "gitops-sync"
}

func validateNodeAffinity(podSpec map[string]any, requested map[string]string) error {
	affinity, ok := podSpec["affinity"].(map[string]any)
	if !ok {
		return nil
	}
	nodeAffinity, ok := affinity["nodeAffinity"].(map[string]any)
	if !ok {
		return nil
	}
	required, ok := nodeAffinity["requiredDuringSchedulingIgnoredDuringExecution"].(map[string]any)
	if !ok {
		return nil
	}
	terms, ok := required["nodeSelectorTerms"].([]any)
	if !ok || len(terms) == 0 {
		return fmt.Errorf("required node affinity has no valid nodeSelectorTerms")
	}

	for _, termValue := range terms {
		term, ok := termValue.(map[string]any)
		if !ok {
			return fmt.Errorf("required node affinity contains an invalid nodeSelectorTerm")
		}
		compatible := true
		expressions, _ := term["matchExpressions"].([]any)
		for _, expressionValue := range expressions {
			expression, ok := expressionValue.(map[string]any)
			if !ok {
				return fmt.Errorf("required node affinity contains an invalid matchExpression")
			}
			key, _ := expression["key"].(string)
			requestedValue, constrained := requested[key]
			if !constrained {
				continue
			}
			operator, _ := expression["operator"].(string)
			values, _ := expression["values"].([]any)
			allowed, err := affinityAllows(operator, values, requestedValue)
			if err != nil {
				return fmt.Errorf("cannot verify required node affinity for selector key %q: %w", key, err)
			}
			if !allowed {
				compatible = false
				break
			}
		}
		if compatible {
			return nil
		}
	}

	return fmt.Errorf("infrastructure node selector conflicts with required node affinity; choose values compatible with the workload's mandatory placement")
}

func affinityAllows(operator string, values []any, requested string) (bool, error) {
	contains := false
	for _, value := range values {
		stringValue, ok := value.(string)
		if !ok {
			return false, fmt.Errorf("affinity values must be strings")
		}
		if stringValue == requested {
			contains = true
		}
	}
	switch operator {
	case "In", "Equals":
		return contains, nil
	case "NotIn":
		return !contains, nil
	case "Exists":
		return true, nil
	case "DoesNotExist":
		return false, nil
	case "Gt", "Lt":
		if len(values) != 1 {
			return false, fmt.Errorf("%s requires exactly one value", operator)
		}
		boundValue, ok := values[0].(string)
		if !ok {
			return false, fmt.Errorf("affinity values must be strings")
		}
		requestedNumber, requestedErr := strconv.ParseInt(requested, 10, 64)
		boundNumber, boundErr := strconv.ParseInt(boundValue, 10, 64)
		if requestedErr != nil || boundErr != nil {
			return false, fmt.Errorf("%s affinity comparison requires integer label values", operator)
		}
		if operator == "Gt" {
			return requestedNumber > boundNumber, nil
		}
		return requestedNumber < boundNumber, nil
	default:
		return false, fmt.Errorf("unsupported node affinity operator %q", operator)
	}
}

func workloadPodSpec(document map[string]any, kind string) map[string]any {
	apiVersion, _ := document["apiVersion"].(string)
	switch apiVersion + "/" + kind {
	case "monitoring.coreos.com/v1/Prometheus", "monitoring.coreos.com/v1/Alertmanager":
		return nestedMap(document, "spec")
	case "gateway.nginx.org/v1alpha2/NginxProxy":
		return nestedMap(document, "spec", "kubernetes", "deployment", "pod")
	}
	switch kind {
	case "Deployment", "StatefulSet":
		return nestedMap(document, "spec", "template", "spec")
	case "Job":
		return nestedMap(document, "spec", "template", "spec")
	case "CronJob":
		return nestedMap(document, "spec", "jobTemplate", "spec", "template", "spec")
	default:
		return nil
	}
}

func nestedMap(object map[string]any, path ...string) map[string]any {
	current := object
	for _, key := range path {
		value, exists := current[key]
		if !exists {
			value = make(map[string]any)
			current[key] = value
		}
		next, ok := value.(map[string]any)
		if !ok {
			return nil
		}
		current = next
	}
	return current
}

func nodeSelector(podSpec map[string]any) (map[string]string, error) {
	existingValue, exists := podSpec["nodeSelector"]
	if !exists {
		return map[string]string{}, nil
	}
	existingMap, ok := existingValue.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("nodeSelector must be a map of label keys to values")
	}
	selector := make(map[string]string, len(existingMap))
	for key, value := range existingMap {
		stringValue, ok := value.(string)
		if !ok {
			return nil, fmt.Errorf("nodeSelector value for %q must be a string", key)
		}
		selector[key] = stringValue
	}
	return selector, nil
}

func manifestIdentity(document map[string]any) string {
	kind, _ := document["kind"].(string)
	metadata, _ := document["metadata"].(map[string]any)
	name, _ := metadata["name"].(string)
	if name == "" {
		return kind
	}
	return kind + "/" + name
}

func validateResourceGroup(document map[string]any) error {
	apiVersion, _ := document["apiVersion"].(string)
	kind, _ := document["kind"].(string)
	switch apiVersion + "/" + kind {
	case "monitoring.coreos.com/v1/Prometheus", "monitoring.coreos.com/v1/Alertmanager",
		"monitoring.coreos.com/v1/ServiceMonitor", "monitoring.coreos.com/v1/PodMonitor", "monitoring.coreos.com/v1/PrometheusRule",
		"gateway.nginx.org/v1alpha2/NginxProxy",
		"gateway.nginx.org/v1alpha1/NginxGateway", "gateway.networking.k8s.io/v1/GatewayClass":
		return nil
	}
	if !strings.Contains(apiVersion, "/") {
		return nil
	}

	group, _, _ := strings.Cut(apiVersion, "/")
	switch group {
	case "admissionregistration.k8s.io", "apiregistration.k8s.io", "apps", "batch", "coordination.k8s.io", "discovery.k8s.io", "events.k8s.io",
		"networking.k8s.io", "node.k8s.io", "policy", "rbac.authorization.k8s.io",
		"scheduling.k8s.io", "storage.k8s.io", "apiextensions.k8s.io":
		return nil
	default:
		return fmt.Errorf("custom resource API group %q is not supported by generic infrastructure placement rendering", group)
	}
}
