const std = @import("std");
const builtin = @import("builtin");

/// This variable is `true` if an atomic reference-counter is used for `Arc`, `false` otherwise.
///
/// If the target is single-threaded, `Arc` is optimized to a regular `Rc`.
pub const atomic_arc = !builtin.single_threaded or (builtin.target.isWasm() and std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics));
