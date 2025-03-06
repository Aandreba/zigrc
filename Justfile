coverage: clean
    rm -rf kcov-out
    zig build test -Doptimize=Debug
    kcov --include-pattern=src/root.zig,src/tests.zig kcov-out .zig-cache/o/**/test

docs:
    zig build
    xdg-open http://localhost:3000/
    bun run docs/index.ts

test:
    zig test src/tests.zig

clean:
    rm -rf zig-cache
    rm -rf zig-out
