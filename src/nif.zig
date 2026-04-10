const std = @import("std");
const processor = @import("flame_on_processor");

// ============================================================================
// Erlang NIF types — defined in Zig to avoid C header cross-compilation issues.
// These match the OTP 26+ NIF API (version 2.17) for 64-bit targets.
// ============================================================================

const ERL_NIF_TERM = usize;
const ErlNifEnv = opaque {};

const ErlNifBinary = extern struct {
    size: usize,
    data: [*]u8,
    ref_bin: ?*anyopaque,
    __spare__: [2]?*anyopaque,
};

const ErlNifMapIterator = extern struct {
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

const ErlNifMapIteratorEntry = enum(c_int) {
    FIRST = 1,
    LAST = 2,
};

const NifFunc = extern struct {
    name: [*:0]const u8,
    arity: c_uint,
    fptr: *const fn (?*ErlNifEnv, c_int, [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM,
    flags: c_uint,
};

const ErlNifEntry = extern struct {
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

const ERL_NIF_DIRTY_JOB_CPU_BOUND: c_uint = 1;

// ============================================================================
// Extern NIF API functions — resolved at load time by the BEAM VM.
// ============================================================================

extern fn enif_map_iterator_create(env: ?*ErlNifEnv, map: ERL_NIF_TERM, iter: *ErlNifMapIterator, entry: ErlNifMapIteratorEntry) callconv(.c) c_int;
extern fn enif_map_iterator_get_pair(env: ?*ErlNifEnv, iter: *ErlNifMapIterator, key: *ERL_NIF_TERM, value: *ERL_NIF_TERM) callconv(.c) c_int;
extern fn enif_map_iterator_next(env: ?*ErlNifEnv, iter: *ErlNifMapIterator) callconv(.c) void;
extern fn enif_map_iterator_destroy(env: ?*ErlNifEnv, iter: *ErlNifMapIterator) callconv(.c) void;
extern fn enif_inspect_binary(env: ?*ErlNifEnv, term: ERL_NIF_TERM, bin: *ErlNifBinary) callconv(.c) c_int;
extern fn enif_get_double(env: ?*ErlNifEnv, term: ERL_NIF_TERM, dp: *f64) callconv(.c) c_int;
extern fn enif_get_ulong(env: ?*ErlNifEnv, term: ERL_NIF_TERM, val: *c_ulong) callconv(.c) c_int;
extern fn enif_get_long(env: ?*ErlNifEnv, term: ERL_NIF_TERM, val: *c_long) callconv(.c) c_int;
extern fn enif_alloc_binary(size: usize, bin: *ErlNifBinary) callconv(.c) c_int;
extern fn enif_make_binary(env: ?*ErlNifEnv, bin: *ErlNifBinary) callconv(.c) ERL_NIF_TERM;
extern fn enif_make_atom(env: ?*ErlNifEnv, name: [*:0]const u8) callconv(.c) ERL_NIF_TERM;
extern fn enif_make_tuple_from_array(env: ?*ErlNifEnv, arr: [*]const ERL_NIF_TERM, count: c_uint) callconv(.c) ERL_NIF_TERM;
extern fn enif_alloc(size: usize) callconv(.c) ?*anyopaque;
extern fn enif_free(ptr: ?*anyopaque) callconv(.c) void;
extern fn enif_get_map_size(env: ?*ErlNifEnv, map: ERL_NIF_TERM, size: *usize) callconv(.c) c_int;

// ============================================================================
// enif-backed allocator for use with the processor library.
// ============================================================================

const enif_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &enif_allocator_vtable,
};

const enif_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = enifAlloc,
    .resize = enifResize,
    .remap = enifRemap,
    .free = enifFree,
};

fn enifAlloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const ptr = enif_alloc(len) orelse return null;
    return @as([*]u8, @ptrCast(ptr));
}

fn enifResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    // enif has no realloc-in-place; signal failure so the allocator falls back.
    return false;
}

fn enifRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    // Allocate a new buffer — caller will copy data and free the old one.
    const ptr = enif_alloc(new_len) orelse return null;
    return @as([*]u8, @ptrCast(ptr));
}

fn enifFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    enif_free(@as(?*anyopaque, @ptrCast(memory.ptr)));
}

// ============================================================================
// NIF entry point
// ============================================================================

var funcs = [_]NifFunc{
    .{
        .name = "process_stacks",
        .arity = 2,
        .fptr = &processStacksNif,
        .flags = ERL_NIF_DIRTY_JOB_CPU_BOUND,
    },
};

var entry = ErlNifEntry{
    .major = 2,
    .minor = 17,
    .name = "Elixir.FlameOn.Client.NativeProcessor",
    .num_of_funcs = 1,
    .funcs = &funcs,
    .load = null,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = "beam.vanilla",
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = 40, // sizeof(ErlNifResourceTypeInit) on 64-bit
    .min_erts = "erts-14.0",
};

export fn nif_init() *ErlNifEntry {
    return &entry;
}

// ============================================================================
// process_stacks/2 NIF implementation
//
// Args: map :: %{binary() => non_neg_integer()}, threshold :: float()
// Returns: {:ok, binary()} | {:error, :processing_failed}
// ============================================================================

fn processStacksNif(env: ?*ErlNifEnv, argc: c_int, argv: [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    if (argc != 2) return makeError(env);

    // 1. Extract threshold from argv[1]
    var threshold: f64 = 0.0;
    if (enif_get_double(env, argv[1], &threshold) == 0) return makeError(env);

    // 2. Get map size
    var map_size: usize = 0;
    if (enif_get_map_size(env, argv[0], &map_size) == 0) return makeError(env);

    // 3. Allocate slices for paths and durations
    const paths_buf = enif_alloc(map_size * @sizeOf([*]const u8)) orelse return makeError(env);
    defer enif_free(paths_buf);
    const paths: [*][]const u8 = @ptrCast(@alignCast(paths_buf));

    const durations_buf = enif_alloc(map_size * @sizeOf(u64)) orelse return makeError(env);
    defer enif_free(durations_buf);
    const durations: [*]u64 = @ptrCast(@alignCast(durations_buf));

    // 4. Iterate map and fill slices
    var iter: ErlNifMapIterator = undefined;
    if (enif_map_iterator_create(env, argv[0], &iter, .FIRST) == 0) return makeError(env);
    defer enif_map_iterator_destroy(env, &iter);

    var i: usize = 0;
    while (i < map_size) : (i += 1) {
        var key: ERL_NIF_TERM = 0;
        var value: ERL_NIF_TERM = 0;
        if (enif_map_iterator_get_pair(env, &iter, &key, &value) == 0) return makeError(env);

        // Key is a binary (path string)
        var bin: ErlNifBinary = undefined;
        if (enif_inspect_binary(env, key, &bin) == 0) return makeError(env);
        paths[i] = bin.data[0..bin.size];

        // Value is an integer (duration in microseconds)
        var dur_signed: c_long = 0;
        if (enif_get_long(env, value, &dur_signed) == 0) return makeError(env);
        if (dur_signed < 0) return makeError(env);
        durations[i] = @intCast(dur_signed);

        enif_map_iterator_next(env, &iter);
    }

    // 5. Call the processor
    const paths_slice = paths[0..map_size];
    const durations_slice = durations[0..map_size];

    const result = processor.processor.process(
        enif_allocator,
        paths_slice,
        durations_slice,
        threshold,
    ) catch return makeError(env);

    // 6. Build the result binary and return {:ok, binary}
    var result_bin: ErlNifBinary = undefined;
    if (enif_alloc_binary(result.len, &result_bin) == 0) {
        enif_allocator.free(result);
        return makeError(env);
    }
    @memcpy(result_bin.data[0..result.len], result);
    enif_allocator.free(result);

    const ok_atom = enif_make_atom(env, "ok");
    const bin_term = enif_make_binary(env, &result_bin);
    const ok_tuple = [_]ERL_NIF_TERM{ ok_atom, bin_term };
    return enif_make_tuple_from_array(env, &ok_tuple, 2);
}

fn makeError(env: ?*ErlNifEnv) ERL_NIF_TERM {
    const error_atom = enif_make_atom(env, "error");
    const reason_atom = enif_make_atom(env, "processing_failed");
    const err_tuple = [_]ERL_NIF_TERM{ error_atom, reason_atom };
    return enif_make_tuple_from_array(env, &err_tuple, 2);
}
