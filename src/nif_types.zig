// ============================================================================
// Shared Erlang NIF type definitions.
//
// Both nif.zig and tracer_nif.zig import these so that the same opaque types
// are used everywhere, avoiding Zig's distinct-opaque-type constraint.
// These match the OTP 26+ NIF API (version 2.17) for 64-bit targets.
// ============================================================================

pub const ERL_NIF_TERM = usize;
pub const ErlNifEnv = opaque {};

pub const ErlNifBinary = extern struct {
    size: usize,
    data: [*]u8,
    ref_bin: ?*anyopaque,
    __spare__: [2]?*anyopaque,
};

pub const ErlNifMapIterator = extern struct {
    map: ERL_NIF_TERM,
    size: ERL_NIF_TERM,
    idx: ERL_NIF_TERM,
    u: extern union {
        flat: extern struct {
            ks: ?[*]ERL_NIF_TERM,
            vs: ?[*]ERL_NIF_TERM,
        },
        hash: extern struct {
            wstack: ?*anyopaque,
            kv: ?[*]ERL_NIF_TERM,
        },
    },
    __spare__: [2]?*anyopaque,
};

pub const ErlNifMapIteratorEntry = enum(c_int) {
    FIRST = 1,
    LAST = 2,
};

pub const NifFunc = extern struct {
    name: [*:0]const u8,
    arity: c_uint,
    fptr: *const fn (?*ErlNifEnv, c_int, [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM,
    flags: c_uint,
};

pub const ErlNifEntry = extern struct {
    major: c_int,
    minor: c_int,
    name: [*:0]const u8,
    num_of_funcs: c_int,
    funcs: [*]const NifFunc,
    load: ?*const fn (?*ErlNifEnv, *?*anyopaque, ERL_NIF_TERM) callconv(.c) c_int,
    reload: ?*const fn (?*ErlNifEnv, *?*anyopaque, ERL_NIF_TERM) callconv(.c) c_int,
    upgrade: ?*const fn (?*ErlNifEnv, *?*anyopaque, *?*anyopaque, ERL_NIF_TERM) callconv(.c) c_int,
    unload: ?*const fn (?*ErlNifEnv, ?*anyopaque) callconv(.c) void,
    vm_variant: [*:0]const u8,
    options: c_uint,
    sizeof_ErlNifResourceTypeInit: usize,
    min_erts: [*:0]const u8,
};

pub const ErlNifResourceType = opaque {};

pub const ErlNifResourceFlags = enum(c_int) {
    CREATE = 1,
    TAKEOVER = 2,
    CREATE_OR_TAKEOVER = 3,
};

pub const ERL_NIF_DIRTY_JOB_CPU_BOUND: c_uint = 1;
