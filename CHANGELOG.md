# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- `Client.Response.getHeader` and `Client.Response.iterateHeaders`: thread-safe immutable snapshot access to parsed HTTP response headers without cross-thread libcurl handle access.
- `Client.RequestBuilder.bodyReader`: streaming request body upload support from an active `std.Io.Reader`, supporting POST, PUT, and chunked/known-length uploads.
- `Client.RequestBuilder.maxRedirects`: configurable redirect cap using `CURLOPT_MAXREDIRS` to prevent redirect loops.
- `HttpError` typed error set and `errors.httpErrorFrom(code)` mapping `CURLcode` to idiomatic Zig errors (`Timeout`, `NameResolutionFailed`, `ConnectionFailed`, `TooManyRedirects`, `ClientClosed`, etc.).
- Re-export `Header`, `HeaderIterator`, `ResponseHeader`, `ResponseHeaderIterator`, `IterateHeadersOptions`, `HttpError`, and `HeaderError` at package root.

### Changed

- Replaced ambiguous `CURLE_COULDNT_CONNECT` mapping from `ConnectionRefused` to `ConnectionFailed`.
- Mapped client abort during shutdown (`abortStream`) to `error.ClientClosed`.
- Note for consumers (Breaking error surface): Transfer failures are now typed via `HttpError` rather than defaulting to generic `error.HttpTransferFailed`. Redirect loops yield `error.TooManyRedirects`, timeouts yield `error.Timeout`, and shutdown aborts yield `error.ClientClosed`.

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
