coverage: clean
    zig build test
    kcov --include-pattern=src/main.zig,src/tests.zig kcov-out zig-cache/o/**/test

docs:
    zig build

test:
    zig test src/tests.zig

clean:
    rm -rf zig-cache
    rm -rf zig-out
