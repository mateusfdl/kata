.PHONY: build release release-native test run bench bench-dev clean fmt

BINARY := kata

build:
	zig build --prefix . -Doptimize=Debug
	@test -x bin/$(BINARY) || (echo "build did not produce bin/$(BINARY)"; exit 1)

release:
	zig build --prefix . -Doptimize=ReleaseFast -Dcpu=x86_64_v3
	@strip -s bin/$(BINARY) 2>/dev/null || true

release-native:
	zig build --prefix . -Doptimize=ReleaseFast -Dcpu=native
	@strip -s bin/$(BINARY) 2>/dev/null || true

test:
	zig build test --test-timeout 500ms

run:
	zig build run -- $(ARGS)

bench: release-native
	./bench.sh

bench-dev: build
	./bench.sh

fmt:
	zig fmt src tools build.zig

clean:
	rm -rf bin zig-out zig-pkg .zig-cache
