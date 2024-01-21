#!/usr/bin/env bash

set -x
zip -r  /tmp/z.zip /*.zig src build.zig build.zig.zon libs \
    -x /*DS_Store
