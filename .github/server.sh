#!/usr/bin/env bash

set -Eeuo pipefail

SERVER=/tmp/echo-server
go build -o ${SERVER} server/main.go
${SERVER} &
sleep 10
