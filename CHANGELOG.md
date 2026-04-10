# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.0.1] - 2026-04-10

### Added

- Flame graph profile processor that filters and encodes to pprof protobuf
- Profile filter that removes functions below a configurable time threshold with small subtree consolidation
- pprof protobuf encoder with string table deduplication
- Low-level protobuf encoding primitives
- CI workflow for ubuntu x86, ubuntu ARM, and macOS
- MIT license
