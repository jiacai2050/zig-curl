# AGENTS.md

Core constraints, architectural rules, and lessons learned for AI coding agents developing `zig-curl`.

---

## 1. Concurrency & Architecture Guardrails

- **`Client` Thread Model**: The single background driver thread exclusively owns `CURLM` and all active `CURL*` handles. `send()` returns immediately once response headers arrive; the body streams concurrently in the background.
- **Strictly No Cross-Thread `CURL*` Access**: The caller thread **must never touch** `stream.easy.handle` (calling `curl_easy_header` or `curl_easy_getinfo` introduces a severe data race).
  - **Rule**: All response metadata (status codes, headers, etc.) must be snapshotted to thread-safe memory inside driver-thread callbacks.
- **Upload Stream (`bodyReader`) Lifetime & Deadlock**:
  - `reader` **must stay valid until `res.deinit()` is called** or until the transfer is fully done (do not assume it can be freed after `send()` returns).
  - `reader` blocks synchronously on the driver thread: **never depend on the same `Client` instance inside the reader**, or it will deadlock the driver thread.
- **Request Method Semantics**: POST streaming uploads require `CURLOPT_POST=1` and `CURLOPT_POSTFIELDSIZE_LARGE` (`-1` for chunked when length is unknown). Use `CURLOPT_UPLOAD=1` only for PUT and other upload methods.
- **Handle Pool Tainting**: Any handle modifying socket or connection routing options (Unix socket, custom hooks) must be marked `is_tainted` and destroyed after use. Never return it to the reuse pool.

---

## 2. Error Handling Philosophy

- **No Catch-All Errors**: Avoid falling back unconditionally to `error.HttpTransferFailed` or `error.Curl`.
- **Typed Semantic Errors**: Use `errors.httpErrorFrom(code)` to map `CURLcode` to precise variants (`ConnectionFailed`, `Timeout`, `TooManyRedirects`, `ClientClosed`, etc.). Always assert `assert(code != c.CURLE_OK)` before mapping.

---

## 3. Testing & Quality Standards

1. **Verify Wire Data & Methods**: Mock server tests for uploads **must read and assert the full request body and HTTP method** (never return 200 after merely receiving the head).
2. **Test Error & Interruption Paths**: Explicitly cover reader failures, timeouts, redirect loops, and in-flight `client.deinit()` calls.
3. **Hermetic & Offline**: Use loopback addresses only (`127.0.0.1:0`) with `(offline local)` description suffixes. Ensure 100% zero-leak under `SafeAllocator`.
4. **Gates & Synchronization**:
   - `zig build test` passes cleanly without memory leaks.
   - `zig build check` builds all examples without warnings.
   - `zig fmt --check <files>` passes formatting checks.
   - Re-export new public APIs / error types symmetrically in `src/root.zig` and update `CHANGELOG.md`.
