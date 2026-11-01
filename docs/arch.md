# Architecture of `zig-curl` Client

This document details the internal design, concurrency model, memory lifecycle, and flow-control mechanisms of the high-level `Client` in `zig-curl`.

---

## 1. Concurrency Model: Dedicated Driver Reactor

`zig-curl` features an asynchronous, zero-idle-CPU reactor architecture decoupling caller execution from libcurl’s state machine.

```
+-------------------------------------------------------------------+
|                           Caller Threads                          |
|  client.get(...).send(io)                 response.reader().read()|
+----------------------+-----------------------------^--------------+
                       | push                        | copy
                       v                             |
        +------------------------------+             |
        | pending_queue (SpinLock)     |             |
        +--------------+---------------+             |
                       | atomic batch drain          |
                       v                             |
+----------------------------------------------------+--------------+
|                   Background Driver Thread                        |
|                                                                   |
|   +-----------------------+              +---------------------+  |
|   |   active_list (FIFO)  |              |  ring_buffer (64KB) |  |
|   |   (Exclusively owned) |              |  (Per Stream)       |  |
|   +-----------+-----------+              +----------^----------+  |
|               |                                     |             |
|               v                                     | write       |
|       curl_multi_poll()                             | chunks      |
|               |                                     |             |
|               v                                     |             |
|      curl_multi_perform() ----------> streamWriteCallback         |
+-------------------------------------------------------------------+
```

### Thread Ownership & No Cross-Thread Handle Access
- **Driver Thread Exclusive Ownership**: The dedicated background driver thread exclusively manages `CURLM*` and all registered `CURL*` (`Easy`) handles.
- **Strictly No Cross-Thread `CURL*` Calls**: Caller threads never touch `stream.easy.handle` (e.g., invoking `curl_easy_getinfo` or `curl_easy_header` from caller threads causes a severe data race inside libcurl).
- **Immutable Snapshot**: All response metadata (HTTP status codes, response headers) is copied into a thread-safe contiguous buffer on the driver thread before `headers_ready` is signaled. Once published, callers read from this immutable snapshot concurrently without locks.

### Zero-CPU Idle Reactor
- When `active_list == null`, the driver thread unconditionally suspends on `idle_event.waitUncancelable(io)`. It executes **no `curl_multi_poll`** and sets **no periodic timer**, maintaining true 0% CPU consumption during idle periods.
- New submissions or `client.deinit()` awaken the driver instantly via `idle_event.set()` and `curl_multi_wakeup()`.

---

## 2. Memory Lifecycle & Zero-Allocation Pooling

Each HTTP request is represented by a `StreamContext`, which encapsulates both the libcurl `Easy` handle and internal streaming state.

```
       acquireStream() (reused from pool)
             │
             ▼
     ┌────────────────┐
     │ StreamContext  │ ref_count = 2
     └───────┬────────┘
             │
    ┌────────┴────────┐
    ▼                 ▼
Caller/Response    Driver Thread
(ref_count - 1)    (ref_count - 1)
    │                 │
    ▼                 ▼
res.deinit()       onTransferDone()
    │                 │
    └────────┬────────┘
             │ ref_count == 0
             ▼
      releaseHandle()
     (Clean: back to pool;
      Tainted: destroy)
```

### 1. Dual Reference Counting
- `ref_count` is initialized to `2`:
  - **1 reference** held by the caller / `Response` (released upon `res.deinit()` or submission failure).
  - **1 reference** held by the background driver thread (released when `CURLMSG_DONE` triggers `onTransferDone()`).
- The stream and underlying `Easy` handle are returned to `HandlePool` (or destroyed) only when `ref_count` drops to `0`.

### 2. Zero-Allocation Hot Path
- `StreamContext` objects are pooled together with `Easy` handles in `HandlePool` (up to `pool_max_capacity = 64`).
- **64 KB Ring Buffer**: Embedded directly in `StreamContext`. It is reused across requests without memory allocation or kernel page-table remapping.
- **Stack Formatted Headers**: `buildHeaderSlist` uses a 512-byte stack buffer via `std.fmt.bufPrintSentinel`, completely eliminating heap allocations for standard HTTP headers (e.g., Authorization tokens, Cookies).
- **Self-Healing Header Buffers**: In `StreamContext.reset()`, if `header_bytes` exceeds 16 KB or `headers` exceeds 128 entries due to an anomalous upstream response, the buffer is freed and reset to avoid permanent idle memory retention.

### 3. Taint Isolation Pattern
- Any handle whose connection routing or socket configuration is modified (such as Unix domain sockets or native `.configure()` hooks) is permanently flagged `is_tainted = true`.
- Upon release, tainted handles are destroyed immediately and never returned to the clean reuse pool.

---

## 3. Streaming Flow Control & Backpressure

To prevent memory bloat when streaming large responses to a slow consumer:

1. **Backpressure (Pause)**:
   - When the driver receives incoming response chunks via `streamWriteCallback` and remaining space in the 64 KB ring buffer is smaller than the chunk size, the stream sets `stream.paused = true` and returns `CURL_WRITEFUNC_PAUSE`.
   - libcurl pauses socket reads for this specific transfer while other transfers in the multi handle continue processing at full speed.
2. **Unpause Threshold**:
   - As the caller drains bytes via `res.reader().read()`, once free space in `ring_buffer` reaches `ring_unpause_threshold_bytes` (16 KB), the caller sets `needs_unpause = true` and wakes the driver via `curl_multi_wakeup()`.
   - In `maintainActiveStreams()`, the driver invokes `curl_easy_pause(handle, CURLPAUSE_CONT)` outside mutex boundaries to resume wire transfers.

---

## 4. Request Submission Lifecycle

```
RequestBuilder.send()
  │
  ├── 1. Acquire Concurrency Permit (if max_concurrency configured)
  │
  ├── 2. acquireStream() (from HandlePool or createFreshStream)
  │
  ├── 3. setupAndEnqueue()
  │       ├── Reset StreamContext in-place
  │       ├── Apply options (URL, Method, Headers, Timeout)
  │       ├── Push to pending_queue (SpinLock)
  │       └── Wake driver (idle_event + curl_multi_wakeup)
  │
  └── 4. Wait on header_event.waitUncancelable(io)
          ├── Failure: releaseRef(), map HttpError, return error
          └── Success: return Response (caller now owns 1 ref)
```
