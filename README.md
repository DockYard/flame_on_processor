# flame_on_processor

[![CI](https://github.com/DockYard/flame_on_processor/actions/workflows/ci.yml/badge.svg)](https://github.com/DockYard/flame_on_processor/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Zig library that transforms flame graph profiling data into the [pprof](https://github.com/google/pprof) protobuf format.

It takes semicolon-delimited stack paths paired with durations, filters out functions that fall below a configurable time threshold, and encodes the result as a pprof `Profile` protobuf — ready for visualization in tools like [pprof](https://github.com/google/pprof) and [speedscope](https://www.speedscope.app).

## Platform Support

Tested on Linux (x86_64, aarch64), macOS (aarch64), and Windows (x86_64).

## Installation

Requires **Zig 0.15.2+**.

```sh
zig fetch --save git+https://github.com/DockYard/flame_on_processor.git
```

Then add the dependency in your `build.zig`:

```zig
const flame_on_processor = b.dependency("flame_on_processor", .{
    .target = target,
});
exe.root_module.addImport("flame_on_processor", flame_on_processor.module("flame_on_processor"));
```

## Usage

```zig
const processor = @import("flame_on_processor").processor;

const encoded = try processor.process(
    allocator,
    &.{ "main;compute", "main;render", "main;idle" },
    &.{ 3000, 4000, 200 },
    0.01, // filter threshold: fraction of total time
);
defer allocator.free(encoded);
// `encoded` contains pprof protobuf bytes
```

### Parameters

| Parameter   | Type                    | Description                                                                 |
|-------------|-------------------------|-----------------------------------------------------------------------------|
| `allocator` | `std.mem.Allocator`     | Allocator for all internal and returned memory                              |
| `paths`     | `[]const []const u8`    | Semicolon-delimited stack traces (e.g. `"main;compute;render"`)             |
| `durations` | `[]const u64`           | Duration in microseconds for each path (parallel array)                     |
| `threshold` | `f64`                   | Fraction of total time below which functions are filtered out (min `0.005`) |

Returns an allocated `[]u8` containing the protobuf-encoded pprof Profile. Caller owns the memory.

## Architecture

```
         paths + durations
               │
               ▼
      ┌─────────────────┐
      │    processor     │   top-level API
      └────────┬────────┘
               │
       ┌───────┴───────┐
       ▼               ▼
┌──────────────┐ ┌──────────────┐
│profile_filter│ │pprof_encoder │
└──────────────┘ └──────┬───────┘
                        │
                        ▼
                 ┌──────────────┐
                 │   protobuf   │
                 └──────────────┘
```

- **processor** — top-level API: filter then encode in one call
- **profile_filter** — removes functions whose inclusive time falls below the threshold, consolidating small subtrees into placeholder entries
- **pprof_encoder** — encodes filtered samples into pprof protobuf wire format with proper string table deduplication
- **protobuf** — low-level protobuf encoding primitives (varints, length-delimited fields, packed arrays)

## Development

```sh
zig build            # build the library
zig build test       # run all tests
```

## License

[MIT](LICENSE) - Copyright (c) 2025 DockYard, Inc.
