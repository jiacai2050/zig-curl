
prepare:
	./libs/download.sh

run:
	zig build run-basic -freference-trace
	zig build run-advanced -freference-trace

test:
	zig build test

docs:
	zig build-lib -femit-docs src/root.zig

.PHONY: test run docs
