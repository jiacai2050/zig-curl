#!/usr/bin/env bash

set -x
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
TMP_DIR=/tmp/

cd ${TMP_DIR} || exit 1
curl -o mbedtls.zip https://codeload.github.com/Mbed-TLS/mbedtls/zip/refs/tags/v3.5.1
curl -o libcurl.zip https://codeload.github.com/curl/curl/zip/refs/tags/curl-8_5_0
curl -o zlib.zip https://codeload.github.com/madler/zlib/zip/refs/tags/v1.3

unzip mbedtls.zip
unzip libcurl.zip
unzip zlib.zip

mv curl-curl-8_5_0 "${SCRIPT_DIR}/curl"
mv mbedtls-3.5.1 "${SCRIPT_DIR}/mbedtls"
mv zlib-1.3 "${SCRIPT_DIR}/zlib"
