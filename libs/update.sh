#!/usr/bin/env bash

set -xe
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
TMP_DIR="${SCRIPT_DIR}/../zig-cache"

[ -d "${TMP_DIR}" ] || mkdir "${TMP_DIR}"

cd ${TMP_DIR} || exit 1

[ -f mbedtls.zip ] || curl -o mbedtls.zip https://codeload.github.com/Mbed-TLS/mbedtls/zip/refs/tags/v3.5.1
[ -f curl.zip ]    || curl -o curl.zip https://codeload.github.com/curl/curl/zip/refs/tags/curl-8_5_0
[ -f zlib.zip ]    || curl -o zlib.zip https://codeload.github.com/madler/zlib/zip/refs/tags/v1.3

unzip mbedtls.zip
unzip curl.zip
unzip zlib.zip

# Remove old files
rm -rf "${SCRIPT_DIR}/mbedtls" "${SCRIPT_DIR}/zlib" "${SCRIPT_DIR}/curl"
mkdir "${SCRIPT_DIR}/mbedtls" "${SCRIPT_DIR}/zlib" "${SCRIPT_DIR}/curl"

mv curl-curl-8_5_0/include "${SCRIPT_DIR}/curl/include"
mv curl-curl-8_5_0/lib "${SCRIPT_DIR}/curl/lib"
mv mbedtls-3.5.1/include "${SCRIPT_DIR}/mbedtls/include"
mv mbedtls-3.5.1/library "${SCRIPT_DIR}/mbedtls/library"
mv zlib-1.3/*.c "${SCRIPT_DIR}/zlib"
mv zlib-1.3/*.h "${SCRIPT_DIR}/zlib"
