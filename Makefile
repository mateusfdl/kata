.PHONY: build release release-native test run daemon stop clean fmt

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
	zig build test --test-timeout 2000ms

run:
	zig build run -- $(ARGS)

daemon: build
	./bin/$(BINARY)

stop:
	@./bin/$(BINARY) stop

fmt:
	zig fmt src pkg build.zig

clean:
	rm -rf bin zig-out zig-pkg .zig-cache
