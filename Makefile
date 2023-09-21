
run-examples:
	zig build run-basic -freference-trace
	zig build run-advanced -freference-trace

test:
	zig build test

docs:
	zig build-lib -femit-docs src/main.zig

.PHONY: test run-examples docs
