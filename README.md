![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/Aandreba/zig-rc/tests.yml)
[![Docs](https://img.shields.io/badge/docs-zig-blue)](https://aandreba.github.io/zig-rc/)

# Zig-rc

Reference-counted pointers for Zig inspired by Rust's [`Rc`](https://doc.rust-lang.org/stable/std/rc/struct.Rc.html) and [`Arc`](https://doc.rust-lang.org/stable/std/sync/struct.Arc.html)

## Builds

**Genrate docs**
`zig build`

**Run tests**
`zig build test`

**Run examples**
`zig build example`

**Generate coverage report (requires kcov)**
`zig build test -Dcoverage`
