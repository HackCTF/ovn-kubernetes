# syntax=docker/dockerfile:1
FROM golang:1.25

WORKDIR /src

COPY go-controller/ /src/go-controller/

WORKDIR /src/go-controller

ENV CGO_ENABLED=0
ENV GOFLAGS=-mod=vendor

CMD ["go", "test", "-mod=vendor", "-count=1", "-timeout=180s", "./pkg/ovn/"]