#############      builder                                  #############
FROM golang:1.13.6 AS builder

WORKDIR /go/src/github.com/gardener/provider-mock
COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GO111MODULE=on \
        go install -mod=vendor -ldflags -w ./cmd/...

#############      base                                     #############
FROM alpine:3.10.3 AS base

RUN apk add --update bash curl

WORKDIR /

#############      gardener-provider-mock                   #############
FROM base AS gardener-extension-provider-mock

COPY --from=builder /go/bin/gardener-extension-provider-mock /gardener-extension-provider-mock

ENTRYPOINT ["/gardener-extension-provider-mock"]
