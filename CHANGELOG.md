# Changelog

All notable changes to this project will be documented in this file.

## [0.5.1] - 2026-10-05

### Added

- Add `Easy.setProxy`, `Easy.setAcceptEncoding`, and `Easy.setCookieFile`.
- Add downstream integration tests to verify using zig-curl as a dependency.

### Changed

- Refactor build dependency resolution to pass dependencies explicitly and enable concurrent fetching.
- Register the `curl` module unconditionally so consumers can reliably import it during dependency resolution.

## [0.5.0] - 2026-04-18

### Breaking Changes

- Require Zig 0.16.
- Move Zig 0.15 support to the [`0.15` branch](https://github.com/jiacai2050/zig-curl/tree/0.15).

### Changed

- Update the package for Zig 0.16.
- Refresh the examples and documentation for the new release.
