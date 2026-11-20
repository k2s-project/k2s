<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Policy Enforcement with Kyverno

*K2s* ships [Kyverno](https://kyverno.io/) as a policy enforcement framework inside the `security` addon. This guide covers audit mode, enforce mode, sample policies, and `PolicyException` usage.

## Overview

Kyverno is a Kubernetes-native admission controller. When a resource is created or updated, Kyverno evaluates it against active policies and either allows, blocks (enforce mode), or reports the violation (audit mode) before the resource is persisted.

**K2s currently ships the framework only.** No default policies are installed. The cluster admission behaviour is identical to a cluster without Kyverno until you add policies yourself. Default policies may be added later based on feedback and further discussion about what works well across environments.

All Kyverno webhooks are configured with `failurePolicy: Ignore`, meaning Kyverno being unavailable (e.g. during a restart) will never block cluster operations.

## Enabling Kyverno

Kyverno is enabled by default with the security addon:

```console
k2s addons enable security
```

To opt out:

```console
k2s addons enable security --omitPolicyEnf
```

## Audit vs Enforce Mode

Each policy rule has a `validationFailureAction` field:

| Value | Behaviour |
|-------|-----------|
| `Audit` | Violations are recorded in a `PolicyReport` but resources **are not blocked** |
| `Enforce` | Non-compliant resources are **rejected** at admission time with an error message |

**Recommendation:** Always start in `Audit` mode to assess impact. Switch to `Enforce` only after confirming no legitimate workloads are affected.

## Sample Policies

The Kyverno community commonly starts with three broad categories of policies: pod security hardening, governance and metadata rules, and image or supply-chain controls. The examples below reflect those common starting points.

### Disallow privileged containers (audit)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Audit
  rules:
    - name: check-privileged
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            containers:
              - =(securityContext):
                  =(privileged): "false"
```

### Require labels on namespaces (enforce)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-ns-labels
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Namespace
      validate:
        message: "Namespace must have a 'team' label."
        pattern:
          metadata:
            labels:
              team: "?*"
```

### Require images from approved registries (audit)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-approved-registries
spec:
  validationFailureAction: Audit
  rules:
    - name: check-image-registry
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Images must come from approved registries."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ element.image }}"
                    operator: AnyNotIn
                    value:
                      - "ghcr.io/*"
                      - "registry.k8s.io/*"
                      - "shsk2s.azurecr.io/*"
```

## Applying Policies

Apply a policy directly with `kubectl`:

```console
kubectl apply -f my-policy.yaml
```

Or place policy files in `addons/security/manifests/kyverno/policies/` and re-enable the addon. They will be applied automatically on each `k2s addons enable security`.

## Checking Policy Reports

After applying a policy in `Audit` mode, view violations with:

```console
kubectl get policyreport -A
kubectl describe policyreport -n <namespace> <report-name>
```

For cluster-wide reports:

```console
kubectl get clusterpolicyreport
```

## PolicyException Usage

Use a `PolicyException` to exempt specific resources from a policy without modifying the policy itself:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: allow-monitoring-agent
  namespace: monitoring
spec:
  exceptions:
    - policyName: disallow-host-namespaces
      ruleNames:
        - host-namespaces
        - autogen-host-namespaces
  match:
    any:
      - resources:
          kinds:
            - Pod
            - Deployment
          namespaces:
            - monitoring
          names:
            - monitoring-agent*
```

This exempts a specific monitoring workload in the `monitoring` namespace from a policy that disallows host namespaces. This is a common pattern for infrastructure agents and other operational components that sometimes need tighter exceptions than application workloads.

Note: `PolicyException` support must be enabled in Kyverno before these resources are accepted.

## Linkerd Compatibility

In **enhanced security mode** the `kyverno` namespace is automatically meshed into Linkerd: it carries the `linkerd.io/inject: enabled` annotation so all Kyverno controllers run inside the zero-trust mTLS perimeter. The admission webhook port (`9443`) is excluded from inbound proxying (`config.linkerd.io/skip-inbound-ports: "9443"`) so the API server can continue to reach the Kyverno admission webhook directly. In **basic mode** Kyverno is left un-meshed and runs without a sidecar.

When writing policies that validate container counts or specific container names, remember that meshed pods (including Kyverno's own controllers in enhanced mode) carry an additional `linkerd-proxy` sidecar. Add a `PolicyException` for the `linkerd` namespace and any meshed namespaces, or scope your policies to exclude `linkerd.io/inject: enabled` pods until you have confirmed the policy behaves as expected for meshed workloads.

## Further Reading

- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kyverno Policy Library](https://kyverno.io/policies/)
- [PolicyReport specification](https://kyverno.io/docs/policy-reports/)
- [Security Features Overview](security-features.md)