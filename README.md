# flame_on_processor

A Zig library that processes flame graph profiling data into [pprof](https://github.com/google/pprof) protobuf format.

Takes semicolon-delimited stack paths with durations, filters out functions below a configurable time threshold, and encodes the result as a pprof `Profile` protobuf.

## Usage

Add as a Zig package dependency, then import:

```zig
const processor = @import("flame_on_processor").processor;

const encoded = try processor.process(
    allocator,
    &.{ "main;compute", "main;render" },
    &.{ 3000, 4000 },
    0.01, // filter threshold: fraction of total time
);
defer allocator.free(encoded);
// `encoded` is pprof protobuf bytes
```

## Modules

- **processor** — top-level API: filter then encode in one call
- **profile_filter** — removes functions whose inclusive time falls below a threshold fraction, consolidating small subtrees
- **pprof_encoder** — encodes filtered samples into pprof protobuf wire format
- **protobuf** — low-level protobuf encoding primitives

## Building

Requires Zig 0.15+.

```sh
zig build        # build the library
zig build test   # run tests
```
