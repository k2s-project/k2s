<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Adding *K2s* Users
A *K2s* user is a *Windows* user that:

- has administrative access to the *K8s* nodes (authN/authZ)
- can call the *K8s* API (authN only, see [Authorizing Users to Call *K8s* API Endpoints](#authorizing-users-to-call-k8s-api-endpoints))

When *K2s* is being installed, the *Windows* user executing the installation routine will be granted administrator access to the control-plane (via SSH) and worker nodes. In addition, this user will be configured as *K8s* cluster admin (authN via cert).

!!! note
    *K8s* provides different ways to authenticate users (authN). *K2s* uses [X509 client certificates](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#x509-client-certificates){target="_blank"}.

How to enable other *Windows* users on the same host machine to interact with *K2s* will be shown in the following.

## Granting Access to *K2s*
!!! note
    A *Windows* user must have a local profile on the host machine in order to be granted access to *K2s*.

    Additionally, a *Windows* user must have administrator privileges to interact with *K2s* (see [Prerequisites](./installing-k2s.md#prerequisites)).

To grant a specific *Windows* user access to *K2s*, run as *K2s* admin:
```console
k2s system users add -u <username>
```

See `k2s system users add -h` for more options.

!!! tip "Windows Username"
    Typically the *Windows* username can be specified without the domain.

!!! note
    The *Windows* account `NT AUTHORITY\SYSTEM` (`SID S-1-5-18`) is a special case since it is not a user account. Nevertheless, you can specify the system account's name or `SID` to grant the system account access to *K2s*.
    
    Examples how to specify the *Windows* system account:
    ```console
    k2s system users add -u system

    k2s system users add -u "NT AUTHORITY\SYSTEM"
    
    k2s system users add -i S-1-5-18
    ```


??? example "Full Example With Detailed Steps"
    Given that the *Windows* user `desktop1234\john` exists on the host and has a local profile/home directory, the *K2s* admin runs `k2s system users add -u john` which triggers the following steps:
    
    - Creating an SSH key pair for *John* in `c:\users\john\.ssh\k2s\` on the host. The admin must confirm overwriting existing key pairs. Since the SSH key pair was initially created by the admin's *Windows* account, the file security inheritance must be disabled, the *Administrators* group granted full file access (so that the *K2s* admin can revoke/delete *John's* access later) and the admin user must be removed from the ACL, otherwise SSH would complain about too open access permissions when *John* tries to use his SSH key. *John's* public SSH key contains the *K2s*-specific username as comment, i.e. `k2s-desktop1234-john`, so that removing entries only targets SSH fingerprints that have been created by *K2s*. As of now, none of the SSH keys being created by *K2s* are password-protected.
    - Adding control-plane's SSH fingerprint to `c:\users\john\.ssh\known_hosts` file on the host. It removes previous control-plane fingerprint if existing.
    - Adding *John's* SSH fingerprint to `~/.ssh/authorized_keys` on the control-plane. It removes *John's* previous fingerprint if existing.
    - Creating `c:\users\john\.kube\config` if not existing, copying the *K2s* cluster configuration from admin's `kubeconfig`.
    - Signing a new certificate for username `k2s-desktop1234-john` and group `k2s-users` using *K8s's* CA cert on the control-plane.
    - Copying the new certificate to the host, embedding the certificate data for `k2s-desktop1234-john` in `c:\users\john\.kube\config` and deleting the cert files.
    - Adding a new *K8s* context for `k2s-desktop1234-john` to `c:\users\john\.kube\config`, verifying the *K8s* authentication and switching back to previously active context if there was any.

    *John* has access to the control-plane now (authN/authZ) as well as to the *K8s* API (authN). To authorize *John* (authZ) on the *K8s* cluster, see [Authorizing Users to Call *K8s* API Endpoints](#authorizing-users-to-call-k8s-api-endpoints).
    
    
### Access Verification
#### Control-Plane Node
The new user can verify the SSH access to the control-plane by running:

```console
ssh -o StrictHostKeyChecking=no -i "~/.ssh\k2s\id_rsa" "remote@172.19.1.100"
```

where `172.19.1.100` is the IP address of the control-plane and `remote` the *Linux* user with admin privileges.
  
#### *K8s* API
As the new user, run:

```console
kubectl auth whoami -o jsonpath="{.status.userInfo}"
```

The response should look similar to:
```json
{"groups":["k2s-users","system:authenticated"],"username":"k2s-DESKTOP-user1234"}
```

This response proves that *K8s* verified the user cert presented in the current `kubeconfig` and extracted the username and group successfully.

!!! tip
    To run this check for a different *Windows* user, e.g. as admin for a new *K2s* user, specify the `kubeconfig` explicitly:

    ```console
    kubectl auth whoami -o jsonpath="{.status.userInfo} --kubeconfig path\to\other\users\kube\config"
    ```

## Authorizing Users to Call *K8s* API Endpoints
Since *K8s* authorization is highly dependent on use cases and can get very complex, *K2s* does not provide built-in *K8s* authZ besides the cluster admin permissions.

A common approach to *K8s* authZ is [RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/){target="_blank"}.

!!! example "Grant Permissions to Start *K2s*"
    This example shows how to grant the new *K2s* user *John* from the previous example RBAC-based permissions to start the *K2s* cluster and inspect its status.

    To create a role for displaying nodes' status and taint nodes at startup, run:
    
    ```console
    kubectl create clusterrole EditNodesRole --verb="get,list,watch,patch" --resource="nodes"
    ```

    To create a role for displaying Pod status, run:

    ```console
    kubectl create clusterrole ViewPodsRole --verb="get,list,watch" --resource="pods"
    ```

    :information: It is common practice to define roles cluster-wide (i.e. `clusterrole`) and to use them in a narrower scope/context (i.e. `rolebinding`). They can be seen as globally available templates with local instances.
    
    To assign *John* the `EditNodesRole` role, run:

    ```console
    kubectl create clusterrolebinding EditNodesBinding --clusterrole=EditNodesRole --user=k2s-desktop1234-john
    ```
    
    :information: Instead of assigning a role to specific users, roles can also be assigned to groups, e.g. the `k2s-users` group. The downside would be, that roles cannot be removed from specific users if e.g. an admin wants to revoke access to *K2s*.

    To assign *John* the `ViewPodsRole` role in `kube-system` and `kube-flannel` namespaces, run:

    ```console
    kubectl create rolebinding ViewPodsBinding --clusterrole=ViewPodsRole --user=k2s-desktop1234-john -n "kube-system"
    kubectl create rolebinding ViewPodsBinding --clusterrole=ViewPodsRole --user=k2s-desktop1234-john -n "kube-flannel"
    ```

     :information: In contrast to the role `EditNodesRole` which applies to the whole cluster, the role `ViewPodsRole` is only applied in `kube-system` and `kube-flannel` namespaces, therefore scoped to a narrow context.

## Revoking Access
There is no automated or bullet-proof way to revoke access to *K2s* (or removing a *K2s* user respectively). The manual best-effort steps will be described in the following.

### Control-plane
- \[Essential\] On control-plane, remove SSH key fingerprint from `~/.ssh/authorized_keys` for the specific user (entry should contain username with `k2s-` prefix).
- \[Cleanup\] Remove SSH key pair folder `<home-dir>\.ssh\k2s\`.
- \[Cleanup\] Remove control-plane fingerprint from `<home-dir>\.ssh\known_hosts`, normally starting with the control-plane's IP address `172.19.1.100`.

### *K8s* API
#### AuthN
*K8s* offers no mechanism to revoke user certificates. As long as the user holds the certificate (assuming it did not expire yet), the user can authenticate himself to *K8s*. Without permissions, though, the user can only call unrestricted API endpoints like `kubectl version`.

- Assuming the user is unharmful and did not create a copy of his certificate, his credentials including the certificate data can be removed from the `<home-dir>\.kube\config` file. The `k2s-` prefix uniquely identifies the user.
- Additionally, the *K2s* cluster config and corresponding context can be removed. If no more clusters are configured, the whole `kubeconfig` file can be removed.

#### AuthZ
Remove all `rolebinding` and `clusterrolebinding` *K8s* resources associated with the user, e.g. undo the example steps in [Authorizing Users to Call *K8s* API Endpoints](#authorizing-users-to-call-k8s-api-endpoints).

## Caveats
- Without external IAM, *K8s* does not provide user management or means to revoke access when cert authN is being used. As long as a user presents a valid cert, he is authenticated to *K8s*.
- When *K8s*' CA cert expires, all derived user certs have to be re-generated and all `kubeconfig` files must be updated with the new cluster config and user credentials.
- *K2s* does not provide RBAC for control-plane access, all *Windows* users use the same *Linux* admin account.
- There is no info available yet, which *k2s* CLI command requires which *K8s* permissions (RBAC), e.g. for stopping the *K2s* cluster, SSH access to the control-plane is sufficient, whereas for starting the cluster, the *K8s* permissions to patch a node's config is required (see example in [Authorizing Users to Call *K8s* API Endpoints](#authorizing-users-to-call-k8s-api-endpoints)).
- The SSH keys created by *K2s* are not password-protected.