
run-examples:
	zig build run-basic -freference-trace
	zig build run-advanced -freference-trace

test:
	zig build test

.PHONY: test run-examples
