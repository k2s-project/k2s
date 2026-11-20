<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# fluent-bit
## Generate manifests for linux

1. helm repo add fluent https://fluent.github.io/helm-charts
2. helm repo update
3. mkdir somefetchlocation
4. helm fetch fluent/fluent-bit --untar
5. mkdir output
6. helm template -n logging fluent-bit . --output-dir .\output --include-crds --debug --skip-tests

## Build Windows container
1. Download Windows binaries from https://packages.fluentbit.io/windows/fluent-bit-3.0.4-win64.zip
2. Build host process container with buildkit on kubemaster
```
# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -x 172.19.1.1:8181 -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Set proxy for docker engine
sudo mkdir /etc/systemd/system/docker.service.d
sudo nano /etc/systemd/system/docker.service.d/http_proxy.conf
---
[Service]
Environment="HTTP_PROXY=http://172.19.1.1:8181"
Environment="HTTPS_PROXY=http://172.19.1.1:8181"
---

sudo systemctl daemon-reload
sudo systemctl restart docker

# Create image builder for windows
docker buildx create --name img-builder --use --platform windows/amd64 --driver-opt env.http_proxy=172.19.1.1:8181 --driver-opt env.https_proxy=172.19.1.1:8181

# In case of using go mod download in Dockerfile, set http_proxy in Dockerfile
# ENV https_proxy (see point 3)

k2s node copy -i 172.19.1.100 -u remote -s "fluent-bit" -t "/home/remote/"

# Build Dockerfile and export image to tar ball
docker buildx build -t shsk2s.azurecr.io/fluent/fluent-bit:5.0.2 --platform=windows/amd64 -o type=docker,dest=- . > out.tar

# use k2s to export to windows host
k2s node copy -i 172.19.1.100 -u remote -s fluent-bit/out.tar -t out.tar -r

# Import windows image to K2s
k2s image import -t out.tar -w
```

3. Build new host process container image:
```dockerfile
ARG BASE="mcr.microsoft.com/oss/kubernetes/windows-host-process-containers-base-image:v1.0.0"
FROM $BASE

ENV PATH="C:\Windows\system32;C:\Windows;"
COPY fluent-bit/bin/fluent-bit.exe .
ENTRYPOINT ["fluent-bit.exe"]
```
4. update daemonset-windows.yaml with new image version
