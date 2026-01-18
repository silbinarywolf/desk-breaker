// Last tested with Zig 0.15.2
// - include $ZIG_PATH/lib/zig.h

#include "lib/zig.h"

#undef zig_noreturn
#define zig_noreturn _Noreturn

// NOTE(jae): 2026-18-01
// Initially I used this but later I just imported the "lib/compiler_rt.zig" into the Zig artifact.
//
// zig_i128 __multi3(zig_i128 lhs, zig_i128 rhs) { zig_trap(); }
// zig_u128 __udivti3(zig_u128 lhs, zig_u128 rhs) { zig_trap(); }
// zig_i128 __divti3(zig_i128 lhs, zig_i128 rhs) { zig_trap(); }
// zig_u128 __umodti3(zig_u128 lhs, zig_u128 rhs) { zig_trap(); }
// zig_i128 __modti3(zig_i128 lhs, zig_i128 rhs) { zig_trap(); }
