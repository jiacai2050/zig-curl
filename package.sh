#!/usr/bin/env bash

set -x
# rm -rf /tmp/zig-curl.zip
# zip -r  /tmp/zig-curl.zip /*.zig src build.zig build.zig.zon libs \
#     -x /*DS_Store

rm -rf /tmp/zig-curl.tar.gz
tar --exclude='.DS_Store ' -czf /tmp/zig-curl.tar.gz *.zig src build.zig build.zig.zon libs
