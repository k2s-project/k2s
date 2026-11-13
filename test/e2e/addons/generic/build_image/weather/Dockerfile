# SPDX-FileCopyrightText:  © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

######################
# STEP 1 build binary
######################
FROM public.ecr.aws/docker/library/golang:alpine AS builder
LABEL stage=builder

RUN apk add git

# copy needed project files:
ADD . /go/src/weather/

WORKDIR /go/src/weather

RUN go install -v ./...

RUN GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -trimpath -o /go/bin/weather

##########################
# STEP 2 build small image
##########################
FROM public.ecr.aws/docker/library/alpine:edge
# copy executable.
COPY --from=builder /go/bin/weather /bin/weather
# set entry point
ENTRYPOINT ["/bin/weather"]