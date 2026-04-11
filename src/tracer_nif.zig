const std = @import("std");
const fp = @import("flame_on_processor");
const ring_buffer = fp.ring_buffer;
const nif_types = fp.nif_types;
const RingBuffer = ring_buffer.RingBuffer;
const TraceEntry = ring_buffer.TraceEntry;

// ============================================================================
// Import shared NIF types
// ============================================================================

const ERL_NIF_TERM = nif_types.ERL_NIF_TERM;
const ErlNifEnv = nif_types.ErlNifEnv;
const ErlNifResourceType = nif_types.ErlNifResourceType;
const ErlNifResourceFlags = nif_types.ErlNifResourceFlags;

// ============================================================================
// Extern NIF API functions — resolved at load time by the BEAM VM.
// ============================================================================

extern fn enif_make_atom(env: ?*ErlNifEnv, name: [*:0]const u8) callconv(.c) ERL_NIF_TERM;
extern fn enif_make_tuple_from_array(env: ?*ErlNifEnv, arr: [*]const ERL_NIF_TERM, count: c_uint) callconv(.c) ERL_NIF_TERM;
extern fn enif_make_list_from_array(env: ?*ErlNifEnv, arr: [*]const ERL_NIF_TERM, count: c_uint) callconv(.c) ERL_NIF_TERM;
extern fn enif_make_int(env: ?*ErlNifEnv, i: c_int) callconv(.c) ERL_NIF_TERM;
extern fn enif_make_long(env: ?*ErlNifEnv, i: c_long) callconv(.c) ERL_NIF_TERM;
extern fn enif_make_ulong(env: ?*ErlNifEnv, i: c_ulong) callconv(.c) ERL_NIF_TERM;
extern fn enif_get_long(env: ?*ErlNifEnv, term: ERL_NIF_TERM, val: *c_long) callconv(.c) c_int;
extern fn enif_get_tuple(env: ?*ErlNifEnv, term: ERL_NIF_TERM, arity: *c_int, array: *[*]const ERL_NIF_TERM) callconv(.c) c_int;
extern fn enif_make_resource(env: ?*ErlNifEnv, obj: *anyopaque) callconv(.c) ERL_NIF_TERM;
extern fn enif_alloc_resource(typ: *ErlNifResourceType, size: usize) callconv(.c) ?*anyopaque;
extern fn enif_release_resource(obj: *anyopaque) callconv(.c) void;
extern fn enif_get_resource(env: ?*ErlNifEnv, term: ERL_NIF_TERM, typ: *ErlNifResourceType, objp: *?*anyopaque) callconv(.c) c_int;
extern fn enif_open_resource_type(env: ?*ErlNifEnv, module_str: ?[*:0]const u8, name: [*:0]const u8, dtor: ?*const fn (?*ErlNifEnv, *anyopaque) callconv(.c) void, flags: ErlNifResourceFlags, tried: ?*ErlNifResourceFlags) callconv(.c) ?*ErlNifResourceType;

// ============================================================================
// Resource type for the ring buffer
// ============================================================================

/// The resource wraps a pointer to a RingBuffer.
const BufferResource = struct {
    buffer: *RingBuffer,
};

var buffer_resource_type: ?*ErlNifResourceType = null;

/// Destructor called by BEAM GC when the resource reference is collected.
fn buffer_resource_dtor(_: ?*ErlNifEnv, obj: *anyopaque) callconv(.c) void {
    const res: *BufferResource = @ptrCast(@alignCast(obj));
    res.buffer.destroy();
}

/// NIF load callback — registers the resource type.
pub fn nif_load(env: ?*ErlNifEnv, _: *?*anyopaque, _: ERL_NIF_TERM) callconv(.c) c_int {
    buffer_resource_type = enif_open_resource_type(
        env,
        null,
        "trace_buffer",
        &buffer_resource_dtor,
        .CREATE,
        null,
    );
    if (buffer_resource_type == null) return 1;
    return 0;
}

// ============================================================================
// Helper: unwrap a buffer resource from an ERL_NIF_TERM
// ============================================================================

fn unwrap_buffer(env: ?*ErlNifEnv, term: ERL_NIF_TERM) ?*RingBuffer {
    const rt = buffer_resource_type orelse return null;
    var obj: ?*anyopaque = null;
    if (enif_get_resource(env, term, rt, &obj) == 0) return null;
    const res: *BufferResource = @ptrCast(@alignCast(obj orelse return null));
    return res.buffer;
}

// ============================================================================
// Helper: atom comparison using cached atom terms
// ============================================================================

/// We cache atom terms for the trace tags we care about so that enabled/3 and
/// trace/5 can do fast integer comparisons instead of string comparisons.
var atom_call: ERL_NIF_TERM = 0;
var atom_return_to: ERL_NIF_TERM = 0;
var atom_out: ERL_NIF_TERM = 0;
var atom_out_exiting: ERL_NIF_TERM = 0;
var atom_out_exited: ERL_NIF_TERM = 0;
var atom_in: ERL_NIF_TERM = 0;
var atom_in_exiting: ERL_NIF_TERM = 0;
var atom_trace: ERL_NIF_TERM = 0;
var atom_discard: ERL_NIF_TERM = 0;
var atom_remove: ERL_NIF_TERM = 0;
var atom_ok: ERL_NIF_TERM = 0;
var atom_error: ERL_NIF_TERM = 0;

var atoms_initialized: bool = false;

fn ensure_atoms(env: ?*ErlNifEnv) void {
    if (atoms_initialized) return;
    atom_call = enif_make_atom(env, "call");
    atom_return_to = enif_make_atom(env, "return_to");
    atom_out = enif_make_atom(env, "out");
    atom_out_exiting = enif_make_atom(env, "out_exiting");
    atom_out_exited = enif_make_atom(env, "out_exited");
    atom_in = enif_make_atom(env, "in");
    atom_in_exiting = enif_make_atom(env, "in_exiting");
    atom_trace = enif_make_atom(env, "trace");
    atom_discard = enif_make_atom(env, "discard");
    atom_remove = enif_make_atom(env, "remove");
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atoms_initialized = true;
}

// ============================================================================
// erl_tracer callback: enabled/3
//
// Called by the VM before generating a trace event. Must be VERY fast (<50ns).
// Returns: trace | discard | remove
// ============================================================================

pub fn nif_enabled(env: ?*ErlNifEnv, argc: c_int, argv: [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    _ = argc;
    ensure_atoms(env);

    // argv[0] = TraceTag (atom), argv[1] = TracerState (buffer resource), argv[2] = Tracee
    const buf = unwrap_buffer(env, argv[1]) orelse return atom_remove;

    // If not active, tell VM to remove tracing
    if (!buf.is_active()) return atom_remove;

    // Backpressure: if buffer is >90% full, discard events
    if (buf.fill_level() > 0.9) return atom_discard;

    return atom_trace;
}

// ============================================================================
// erl_tracer callback: trace/5
//
// Called by the VM with the actual trace event data.
// Must be fast (~200ns). Return value is ignored.
// ============================================================================

pub fn nif_trace(env: ?*ErlNifEnv, argc: c_int, argv: [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    _ = argc;
    ensure_atoms(env);

    // argv[0] = TraceTag, argv[1] = TracerState, argv[2] = Tracee,
    // argv[3] = TraceTerm, argv[4] = Opts
    const buf = unwrap_buffer(env, argv[1]) orelse return atom_ok;

    const trace_tag = argv[0];
    const trace_term = argv[3];

    // Determine event_type from TraceTag
    var event_type: u8 = undefined;
    if (trace_tag == atom_call) {
        event_type = 0;
    } else if (trace_tag == atom_return_to) {
        event_type = 1;
    } else if (trace_tag == atom_out or trace_tag == atom_out_exiting or trace_tag == atom_out_exited) {
        event_type = 2;
    } else if (trace_tag == atom_in or trace_tag == atom_in_exiting) {
        event_type = 3;
    } else {
        // Unhandled event type — ignore
        return atom_ok;
    }

    // Extract module, function, arity from TraceTerm
    var module: u64 = 0;
    var function: u64 = 0;
    var arity: u8 = 0;

    if (event_type == 0 or event_type == 1) {
        // TraceTerm is {Module, Function, Arity} for call/return_to
        var tuple_arity: c_int = 0;
        var tuple_elements: [*]const ERL_NIF_TERM = undefined;
        if (enif_get_tuple(env, trace_term, &tuple_arity, &tuple_elements) != 0 and tuple_arity >= 3) {
            module = @intCast(tuple_elements[0]);
            function = @intCast(tuple_elements[1]);
            var arity_val: c_long = 0;
            if (enif_get_long(env, tuple_elements[2], &arity_val) != 0) {
                arity = if (arity_val >= 0 and arity_val <= 255)
                    @intCast(@as(u64, @bitCast(arity_val)))
                else
                    0;
            }
        }
    }
    // For out/in events, module/function/arity stay 0

    // Get timestamp. For maximum performance in the hot path, we read the
    // system clock directly rather than parsing the Opts list. This avoids
    // iterating an Erlang list and extracting tuple elements on every trace
    // event. The microsecond-resolution wall clock is sufficient for profiling.
    const raw_ts = std.time.microTimestamp();
    const timestamp_us: u64 = @intCast(@as(u64, @bitCast(@as(i64, raw_ts))));

    const entry = TraceEntry{
        .event_type = event_type,
        .arity = arity,
        .module = module,
        .function = function,
        .timestamp_us = timestamp_us,
    };

    _ = buf.write(entry);
    return atom_ok;
}

// ============================================================================
// NIF: create_trace_buffer/1
//
// Args: capacity :: pos_integer() (number of entries)
// Returns: {:ok, reference()} | {:error, :alloc_failed}
// ============================================================================

pub fn nif_create_trace_buffer(env: ?*ErlNifEnv, argc: c_int, argv: [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    _ = argc;
    ensure_atoms(env);

    var size: c_long = 0;
    if (enif_get_long(env, argv[0], &size) == 0 or size <= 0) {
        return make_error(env, "badarg");
    }

    const capacity: usize = @intCast(@as(u64, @bitCast(size)));
    const buf = RingBuffer.create(capacity) orelse {
        return make_error(env, "alloc_failed");
    };

    // Wrap in a NIF resource
    const rt = buffer_resource_type orelse {
        buf.destroy();
        return make_error(env, "no_resource_type");
    };

    const res_ptr = enif_alloc_resource(rt, @sizeOf(BufferResource)) orelse {
        buf.destroy();
        return make_error(env, "alloc_failed");
    };

    const res: *BufferResource = @ptrCast(@alignCast(res_ptr));
    res.buffer = buf;

    // Make the Erlang term for the resource
    const res_term = enif_make_resource(env, res_ptr);

    // Release our reference — Erlang now owns it
    enif_release_resource(res_ptr);

    const result = [_]ERL_NIF_TERM{ atom_ok, res_term };
    return enif_make_tuple_from_array(env, &result, 2);
}

// ============================================================================
// NIF: drain_trace_buffer/2 (dirty_cpu scheduler)
//
// Args: buffer_resource, max_count :: pos_integer()
// Returns: [{event_type_atom, {module_atom, function_atom, arity}, timestamp_us}, ...]
// ============================================================================

pub fn nif_drain_trace_buffer(env: ?*ErlNifEnv, argc: c_int, argv: [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    _ = argc;
    ensure_atoms(env);

    const buf = unwrap_buffer(env, argv[0]) orelse {
        return make_error(env, "bad_resource");
    };

    var max_count: c_long = 0;
    if (enif_get_long(env, argv[1], &max_count) == 0 or max_count <= 0) {
        return make_error(env, "badarg");
    }

    const count: usize = @intCast(@as(u64, @bitCast(max_count)));

    // Allocate temporary buffer for reading entries
    const read_buf = std.heap.page_allocator.alloc(TraceEntry, count) catch {
        return make_error(env, "alloc_failed");
    };
    defer std.heap.page_allocator.free(read_buf);

    const entries_read = buf.read_batch(read_buf);

    if (entries_read == 0) {
        // Return empty list
        return enif_make_list_from_array(env, undefined, 0);
    }

    // Allocate array for the list terms
    const terms = std.heap.page_allocator.alloc(ERL_NIF_TERM, entries_read) catch {
        return make_error(env, "alloc_failed");
    };
    defer std.heap.page_allocator.free(terms);

    // Pre-make the event type atoms
    const event_atoms = [4]ERL_NIF_TERM{
        enif_make_atom(env, "call"),
        enif_make_atom(env, "return_to"),
        enif_make_atom(env, "out"),
        enif_make_atom(env, "in"),
    };

    for (0..entries_read) |i| {
        const e = read_buf[i];

        // event_type -> atom
        const evt_atom = if (e.event_type < 4)
            event_atoms[e.event_type]
        else
            enif_make_atom(env, "unknown");

        // module and function are raw ERL_NIF_TERM values — cast back
        const mod_term: ERL_NIF_TERM = @intCast(e.module);
        const fun_term: ERL_NIF_TERM = @intCast(e.function);
        const arity_term = enif_make_int(env, @intCast(e.arity));

        // Build MFA tuple: {module, function, arity}
        const mfa = [_]ERL_NIF_TERM{ mod_term, fun_term, arity_term };
        const mfa_tuple = enif_make_tuple_from_array(env, &mfa, 3);

        // Build timestamp term
        const ts_term = enif_make_long(env, @intCast(e.timestamp_us));

        // Build result tuple: {event_type_atom, {mod, fun, arity}, timestamp_us}
        const tuple = [_]ERL_NIF_TERM{ evt_atom, mfa_tuple, ts_term };
        terms[i] = enif_make_tuple_from_array(env, &tuple, 3);
    }

    return enif_make_list_from_array(env, terms.ptr, @intCast(entries_read));
}

// ============================================================================
// NIF: trace_buffer_stats/1
//
// Args: buffer_resource
// Returns: {write_pos, read_pos, capacity, overflow_count}
// ============================================================================

pub fn nif_trace_buffer_stats(env: ?*ErlNifEnv, argc: c_int, argv: [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    _ = argc;
    ensure_atoms(env);

    const buf = unwrap_buffer(env, argv[0]) orelse {
        return make_error(env, "bad_resource");
    };

    const s = buf.stats();
    const tuple = [_]ERL_NIF_TERM{
        enif_make_ulong(env, @intCast(s.write_pos)),
        enif_make_ulong(env, @intCast(s.read_pos)),
        enif_make_ulong(env, @intCast(s.capacity)),
        enif_make_ulong(env, @intCast(s.overflow_count)),
    };
    return enif_make_tuple_from_array(env, &tuple, 4);
}

// ============================================================================
// NIF: set_trace_active/2
//
// Args: buffer_resource, boolean
// Returns: :ok
// ============================================================================

pub fn nif_set_trace_active(env: ?*ErlNifEnv, argc: c_int, argv: [*]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    _ = argc;
    ensure_atoms(env);

    const buf = unwrap_buffer(env, argv[0]) orelse {
        return make_error(env, "bad_resource");
    };

    // argv[1] is true or false atom
    const atom_true = enif_make_atom(env, "true");
    const active = (argv[1] == atom_true);
    buf.set_active(active);

    return atom_ok;
}

// ============================================================================
// Helpers
// ============================================================================

fn make_error(env: ?*ErlNifEnv, reason: [*:0]const u8) ERL_NIF_TERM {
    ensure_atoms(env);
    const err = [_]ERL_NIF_TERM{ atom_error, enif_make_atom(env, reason) };
    return enif_make_tuple_from_array(env, &err, 2);
}
