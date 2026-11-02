# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- **Request Ergonomics**:
  - `RequestBuilder.json(payload: anytype)`: Serializes structs to JSON directly into request body, auto-setting `Content-Type: application/json`.
  - `RequestBuilder.query(params: anytype)`: Appends query parameters from anonymous structs or `[]const QueryParam` slices with automatic libcurl URL escaping.
  - `Response` status inspection helpers: `isSuccess()`, `isClientError()`, `isServerError()`, and `isError()`.
  - Exported `QueryParam` in `src/root.zig`.

### Changed

- **`RequestBuilder.timeout`**: Now accepts `std.Io.Timeout` directly (`.none`, `.duration`, or `.deadline`) instead of raw integer milliseconds, aligning with Zig 0.17 standard I/O conventions.

## [0.6.0] - 2026-11-01

### Added

- **Asynchronous `Client`**: High-level, non-blocking HTTP client integrated with `std.Io` cooperative fibers, featuring fluent request builders (`get`, `post`, etc.), connection pooling, and optional semaphore throttling (`max_concurrency`).
- **Response Ergonomics**: Incremental streaming (`res.reader()`), typed JSON parsing (`res.json()`), buffered reads (`res.bodyAlloc()`), and thread-safe header views (`res.getHeader()`, `res.iterateHeaders()`).
- **Streaming Uploads**: `bodyReader()` on request builders for streaming uploads directly from `std.Io.Reader` (chunked POST and PUT).
- **Typed Semantic Errors**: Granular `HttpError` set (`Timeout`, `ConnectionFailed`, `TooManyRedirects`, `ClientClosed`, `UploadNotRewindable`, etc.) mapped from `CURLcode`.
- **Connection Sharing**: Added `Share` module (`CURLSH`) and `Easy.setShare()` for sharing DNS, connection, and TLS caches.
- **Top-Level Re-exports**: `Client`, `Response`, `Share`, `HttpError`, and headers are now re-exported at the package root.

### Changed

- **Toolchain**: Upgraded to Zig 0.17.0.
- **Response Lifecycle**: Responses must now be explicitly closed with `defer res.deinit()`.

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
