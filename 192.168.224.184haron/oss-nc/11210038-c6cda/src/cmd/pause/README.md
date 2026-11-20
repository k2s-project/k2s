<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

## Projects to build your own base images for windows 

In order to provide a pause image, the following steps need to be done:
1. Build the OS specfic images
2. Test the produced images
3. Build the manifest and publish the OS independent manifest

## 1. Build the OS specfic images

### Build the pause.exe
`pause.exe` is not tracked in Git. Build it in this folder before building the images.

cl pause.c
### or
gcc pause.c -o pause.exe

### Build the wincat.exe
go build wincat.go

### Create the OS specific pause images
### a. windows 10
docker build --build-arg BASE=mcr.microsoft.com/windows/nanoserver:1809 --tag pause-win10-1809:4 -t pause-win10-1809 .
...

### b. windows 11
docker build --build-arg BASE=mcr.microsoft.com/windows/nanoserver:ltsc2022 --tag pause-win11-21h2:4 -t pause-win11-21h2 .
...

### c. push them to registry
docker push pause-win10-1809:4 
...
docker push pause-win11-21h2:4 
...

## 2. Test the images
### a. run on docker
docker run -it --rm pause-win:4
docker run -it --rm pause-win10-20h2:4
...
docker ps
#### b. run on containerd
nerdctl -n k8s.io run -it --rm --network none pause-win:4
nerdctl -n k8s.io run -it --rm --network none pause-win10-20h2:4
nerdctl -n k8s.io run -it --rm --network none ...
nerdctl -n k8s.io ps
#### c. import/export image test
cd <`installation folder`>\bin\containerd
docker image save -o image.tar pause-win10-21h2:1
ctr --namespace k8s.io i import image.tar

## 3. Build and publish the manifest
set DOCKER_CLI_EXPERIMENTAL=enabled
### a. create the manifest
### windows 10
docker manifest create pause-win:4 --amend pause-win10-1809:4
...
### annotate the osversions
### windows 10
docker manifest annotate --os "windows" --arch "amd64" --os-version "10.0.17763.2300" pause-win:4 pause-win10-1809:4
...
### windows 11
docker manifest annotate --os "windows" --arch "amd64" --os-version "10.0.22000.1219" pause-win:4 pause-win11-21h2:4
...
### b. push manifest
docker manifest push pause-win:4

# check manifest
docker manifest inspect pause-win:3


