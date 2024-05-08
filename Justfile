coverage: clean
    zig build test
    kcov --include-pattern=src/main.zig,src/tests.zig kcov-out zig-cache/o/**/test

docs:
    zig build
    bun run docs/index.ts

test:
    zig test src/tests.zig

clean:
    rm -rf zig-cache
    rm -rf zig-out
