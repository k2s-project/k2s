# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

######################
# STEP 1 build binary
######################
FROM public.ecr.aws/docker/library/golang:1.26-alpine AS builder
LABEL stage=builder

RUN apk add --no-cache git

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s" \
    -trimpath \
    -o /clusterip-webhook \
    ./cmd/clusterip-webhook/

##########################
# STEP 2 build small image
##########################
FROM gcr.io/distroless/static:nonroot

COPY --from=builder /clusterip-webhook /clusterip-webhook

USER 65534:65534

ENTRYPOINT ["/clusterip-webhook"]
