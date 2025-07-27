
ARGS = ${ZIG_ARGS}

run:
	zig build run-hello -freference-trace $(ARGS)
	zig build run-basic -freference-trace $(ARGS)
	zig build run-advanced -freference-trace $(ARGS)
	zig build run-multi -freference-trace $(ARGS)
	zig build run-header -freference-trace $(ARGS)

lint:
	zig fmt --check .

test: lint
	zig build test $(ARGS)

docs:
	if [ ! -d zig-out ]; then mkdir zig-out; fi
	zig build-lib --dep build_info -Mbuild_info=src/root.zig -femit-docs=zig-out/docs -fno-emit-bin

clean:
	rm -rf zig-cache zig-out

serve:
	cd server && go run main.go

.PHONY: run lint test docs clean serve
