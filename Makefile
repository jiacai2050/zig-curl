
prepare:
	./libs/update.sh

clean:
	rm -rf zig-cache zig-out

run:
	zig build run-basic -freference-trace -Dlink_vendor
	zig build run-advanced -freference-trace -Dlink_vendor

test:
	zig build test -Dlink_vendor

docs:
	zig build-lib -femit-docs src/root.zig

.PHONY: test run docs clean prepare
