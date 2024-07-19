
ARGS = ${ZIG_ARGS}

prepare:
	./libs/update.sh

clean:
	rm -rf zig-cache zig-out

serve:
	zig run server/main.zig

run:
	zig build run-basic -freference-trace $(ARGS)
	zig build run-advanced -freference-trace $(ARGS)
	zig build run-multi -freference-trace $(ARGS)

test:
	zig build test $(ARGS)

docs:
	if [ ! -d zig-out ]; then mkdir zig-out; fi
	zig build-lib --dep build_info -Mbuild_info=src/root.zig -femit-docs=zig-out/docs -fno-emit-bin

.PHONY: test run docs clean prepare
