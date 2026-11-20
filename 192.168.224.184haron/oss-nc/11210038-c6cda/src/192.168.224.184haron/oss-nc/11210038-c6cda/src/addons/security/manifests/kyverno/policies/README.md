<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Custom Kyverno Policies

Place your custom Kyverno policy YAML files in this directory.

All `*.yaml` files here are applied automatically when the security addon is enabled:

```
k2s addons enable security
```

## Supported resource kinds

- `ClusterPolicy` - cluster-wide rules (applied to all namespaces)
- `Policy` - namespace-scoped rules
- `PolicyException` - exemptions from existing policies

## Example

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Audit
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "The label 'team' is required."
        pattern:
          metadata:
            labels:
              team: "?*"
```

## Notes

- Policies are applied after Kyverno is fully ready, so webhook failures during startup are avoided.
- On backup (`k2s addons backup security`), all live policies are exported and included in the backup archive.
- On restore (`k2s addons restore security`), backed-up policies are re-applied automatically.
- Files in this directory are part of the K2s installation. For policies that should not be committed to the repository, apply them manually with `kubectl apply -f <your-policy.yaml>` after enabling the addon.
