ARGS ?= ${ZIG_ARGS}

ifeq ($(shell uname), Linux)
	SED_ARGS = -i
else # macOS, BSD, etc.
	SED_ARGS = -i ''
endif

run:
	zig build run-basic -freference-trace $(ARGS)
	zig build run-post -freference-trace $(ARGS)
	zig build run-upload -freference-trace $(ARGS)
	zig build run-advanced -freference-trace $(ARGS)
	zig build run-multi -freference-trace $(ARGS)
	zig build run-header -freference-trace $(ARGS)

lint:
	zig fmt --check .

test: lint
	zig build test $(ARGS)

docs:
	zig build docs
	sed $(SED_ARGS) 's|<style type="text/css">|<style type="text/css">\n  img { width: 200px; margin: auto;display: block; }\n|' zig-out/docs/index.html

clean:
	rm -rf zig-cache zig-out

serve:
	cd server && go run main.go

.PHONY: run lint test docs clean serve
