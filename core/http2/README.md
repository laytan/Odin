# core/http2 — Odin HTTP/1.1 Server (v2 Rewrite)

> **Note:** `core/http2` is the clean-slate rewrite of `core/http` (**not** the HTTP/2 protocol). Once v1 is complete and verified, it will move to `core/net/http` (`import "core:net/http"`).

## v1 Scope & Design Goals

- **HTTP/1.1 server only (no built-in TLS)**: Focus on a fast, maintainable, well-tested plain HTTP/1.1 server for v1. TLS termination and HTTP client support can be layered later.
- **Native `core:nbio` integration**: One `nbio.Event_Loop` per worker thread with per-thread connection pools (`xar.Freelist_Array`) and 1-second cached `Date` headers.
- **Dual per-connection arenas**:
  - `transaction_arena`: Lives for a single HTTP request/response cycle (request line, headers, `Ctx` vars, response headers/buffer).
  - `temp_arena`: Bound to `context.temp_allocator`; calling `free_all(context.temp_allocator)` automatically preserves unread `Scanner` bytes and recycles arena blocks to thread-local power-of-two freelists (`4 KiB`–`256 MiB`).
- **Secure by default**:
  - `Quota` & `Progression` enforce byte caps, minimum/maximum timeouts, and minimum transfer rates (`min_rate` / `rate_add`) to resist Slowloris and resource exhaustion.
  - Strict RFC 9112 parsing and header validation to prevent HTTP/1.1 request smuggling (`CL.TE`, `TE.CL`, `TE.TE`), header injection, and hash-table DoS.
- **Upgrade / Hijack support (WebSockets, SSE, custom protocols)**:
  - **In-pool upgrades (`send_heading` + `.Sending`)**: Sends the upgrade response heading (e.g., `101 Switching Protocols`) with an optional `on_sent` callback while keeping `Connection`, `Scanner` (`temp_arena` + `free_all`), `response_defer`, `connection_close`, and `request_set_quota`/`response_set_quota` alive in the server pool.
  - **Raw detach (`connection_detach`)**: Escape hatch that removes the socket from the server pool and returns `(nbio.TCP_Socket, buffered: []byte, err: runtime.Allocator_Error)` to user code.
- **No OS signal hijacking**: `core:net/http` will not register signal handlers; user code owns signals and calls `server_shutdown(&s)`.

---

## Architecture & File Map

| File | Responsibility |
| --- | --- |
| `server.odin` | `Server`, `Server_Options`, `Server_Thread`, `Connection`, `Ctx` (`context_add`/`context_get`), `Request`, `Response`, connection lifecycle, header validation, response heading serialization, shutdown. |
| `scanner.odin` | Pull-based async `Scanner` (`Scan_Splitter`: `split_line`, `split_n`, `split_at_most`), `Content-Length` and `Transfer-Encoding: chunked` body decoding, trailer parsing. |
| `arena.odin` | `Arena` and `_Arena_Block` power-of-two bucketed freelists per thread backed by `virtual.Arena`, with ASAN poisoning. |
| `quota.odin` | `Quota` and `Progression` state machine tracking transfer limits, min/max durations, and min transfer rate for headers, bodies, and responses. |
| `respond.odin` | Streaming primitives (`send`, `send_file`) and response finalizers (`respond`, `respond_bytes`, `respond_handle`, `respond_file`, `respond_file_path`), single-range `Range` and `If-Range` handling. |
| `headers.odin` | Case-insensitive open-addressed hash table using inline-lowercased SipHash (`Headers`), multi-value support (`headers_add`, `headers_get_all_iter`), and readonly protection. |
| `router.odin` | Segment trie router (`Router`) supporting `:param` and `*` prefix wildcards, percent-decoding before matching, and route-registration conflict detection. |
| `handlers.odin` | `Handler` / `Handle_Proc` middleware chain, `logged` middleware, `body_parser` middleware (`Body_Parser_Iterator`, `Body_Parser_Stream`). |
| `http.odin` | `Version`, `Method`, `Requestline`, `Status`, HTTP date formatting/parsing (`date_write`, `date_parse`), request cookie helpers (`request_cookie_get`, `request_cookies_iter`), query string helpers (`query_get`, `query_iter`). |

---

## Current Status & TODOs

### Priority 1: Known Bugs & Cleanups

- [x] **Thread-safe arena backing & bucket reuse (`arena.odin`, `server.odin`)**: `virtual.Arena` already locks internally on `virtual.arena_alloc`; initialized `s.temp_allocator_backing` before `_setup_threads(s)` in `_setup` (and destroy it on thread setup failure), rounded newly allocated blocks up to `1 << (uint(bucket) + SHIFT)` for `bucket < BUCKETS-1` so blocks match `_bucket_to_put`, and fixed the inverted `len(arena.data) >= size` check + `arena.prev` preservation in `BUCKETS-1`.
- [x] **Keep-alive scanner preservation & arena cleanup (`server.odin`, `scanner.odin`, `arena.odin`)**:
  - Updated `scanner_reset` to copy any unread bytes (`buf[read_head:write_head]`) into a fresh block, destroy old `transaction_arena` blocks via `transaction_allocator_destroy(c)`, and account for carried-over bytes in `c.req.progress`; updated `_scanner_free_all` and `scanner_reset` to set `new_arena.last`.
  - Updated `_serve_connection` and `connection_destroy` to destroy `temp_arena` via `temp_allocator_destroy(c)` and added `_server_thread_free_arenas_destroy` (plus unpoisoning newly allocated backing slices) so `_destroy` leaves no poisoned blocks across server lifetimes under `-sanitize:address`.
- [x] **Remove unused quota fields on `Connection.temp` (`server.odin`)**: Removed the `temp` wrapper and unused `headers_quota`, `headers_progression`, `body_quota`, and `body_progression` fields from `Connection`.
- [x] **Linear probing deletion in `Headers` (`headers.odin`, `server.odin`, `scanner.odin`)**: Updated `headers_delete` / `_headers_delete_with_hash` to take `^Headers`, enforce readonly assertions, decrement `m.len`, remove all matching entries for `key`, and perform backward-shift deletion so probe chains remain intact; updated callers in `server.odin` and `scanner.odin`.
- [x] **Fix inverted trailer allowlist & remove heap init (`scanner.odin`)**: Replaced the thread-local heap `allowed_trailers` `Headers` map and `init_allowed_trailers` with a zero-allocation `@(private="file", rodata) FORBIDDEN_TRAILERS` table and updated `header_allowed_trailer` to return `false` on a case-insensitive `_headers_eq` match and `true` otherwise.
- [x] **Missing `return` on invalid request-line (`server.odin`)**: Added missing `return` after `invalid_request(c, ...)` when `requestline_parse` fails in `on_rline` so execution does not fall through and call `respond(&c.res)` twice.
- [x] **Fix response send timeout source (`respond.odin`)**: Updated `send` and `send_file` to read `timeout := c.res.progress.timeout` instead of `c.req.progress.timeout`.
- [x] **Fix `Expect: 100-continue` handling (`server.odin`, `respond.odin`)**: Added `send_continue(&c.res)` to queue `HTTP/1.1 100 Continue\r\n\r\n` without finalizing `c.res.state` or touching `c.res.buf`, and updated `on_headers` to send it for HTTP/1.1 requests and continue into the handler.
- [x] **Suppress body bytes on redirected `HEAD` requests (`respond.odin`)**: Updated `send`, `respond_bytes`, and `send_response_heading` to omit body bytes when `!wants_body(&c.req)` while still writing headers and `Content-Length`.
- [x] **Respect `allocator` parameter in `_scan_line` (`scanner.odin`)**: Updated `_scan_line` to forward its `allocator` parameter to `s.scan.allocator` so `scan_temp_line` uses `&s.c.temp_arena`.
- [x] **Fix `Body_Parser_Stream` `read_at` off-by-one & debug print (`handlers.odin`)**: Removed the leftover `fmt.println` in `body_parser`, fixed `read_at` to iterate `s.state.parts[start_part+1:]`, and fixed part-boundary and EOF handling.
- [x] **Track in-flight operations (`server.odin`, `scanner.odin`)**: Assigned `c.curr_recv` on `nbio.recv_poly` calls (clearing it on callback completion and removing it on close/destroy), cleared `curr_accept` in `_on_accept`, and tracked `curr_date` on `Server_Thread` so shutdown cancels it cleanly.
- [x] **Remove `@(init)` functions in `headers.odin`**: Replaced `init_token_set` with a compile-time constant `Ascii_Set` (`TOKEN_SET`) and renamed/removed `@(init)` from `init_secret` -> `headers_init_hash_secret`, calling `headers_init_hash_secret()` explicitly in `_setup`.

### Priority 2: Security & RFC 9112 Hardening

- [x] **Default quotas in `Server_Options` (`quota.odin`, `server.odin`)**: Added `UNLIMITED_QUOTA` as an explicit unlimited opt-out and `_server_options_apply_defaults` (called in `make_server` and `_setup`) so zero-valued `request_quota`, `body_quota`, and `response_quota` default to `DEFAULT_HEADERS_QUOTA`, `DEFAULT_BODY_QUOTA`, and `DEFAULT_SEND_QUOTA`.
- [x] **Default body & header size/count caps (`quota.odin`, `server.odin`, `scanner.odin`)**:
  - Set `DEFAULT_BODY_QUOTA.max_size` to `10 * mem.Megabyte` and checked `clen > c.req.progress.max` up front in `_body_length` (`413 Payload Too Large`).
  - Lowered `DEFAULT_HEADERS_QUOTA.max_size` to `64 * mem.Kilobyte` and added `Server_Options.max_headers` defaulting to `DEFAULT_MAX_HEADERS` (`128`; `< 0` for unlimited), enforced in `_request_add_header` for both `on_header` and chunked `on_trailer`.
  - Updated `scanner_pump` to return `414 URI Too Long` when `request_quota.max_size` is exhausted before `c.req.line.version` is parsed, and `431 Request Header Fields Too Large` when exceeded during header scanning or `max_headers`.
- [x] **Per-request quota overrides (`quota.odin`, `server.odin`, `scanner.odin`)**: Added `quota: ^Quota` to `Request`/`Response` (pointing to `Server_Options` by default), `progression_set_quota` (recomputing remaining `max` and `timeout` against already-transferred bytes/time), and `request_set_quota(req, ^Quota)` / `response_set_quota(res, ^Quota)`; updated `scanner_on_recv`, `_serve_connection`, `on_headers`, and `on_send` to read `c.req.quota` / `c.res.quota`.
- [x] **Strict request smuggling defenses (`validate_headers`, `header_parse`, `requestline_parse`, `scanner.odin`)**:
  - Updated `validate_headers` to inspect all `Transfer-Encoding` headers via `headers_get_all_iterator` (accepting only a single case-insensitive `chunked` coding on HTTP/1.1), inspect all `Content-Length` headers (`parse_int`, max 1), and reject requests with *both* `Transfer-Encoding` and `Content-Length` (`400 Bad Request` + `Connection: close`).
  - Updated `header_parse` to validate field names with `headers_valid_key`, trim only HTTP OWS (` ` / `\t`), and reject bare `\r`, bare `\n`, NUL, and CTL/DEL bytes via `_valid_field_bytes` (also enforced in chunked `on_size`, with `_headers_eq(enc_header, "chunked")` in `body`).
  - Hardened `version_parse` (digit checks), `parse_int`/`parse_int16` (non-empty), and `requestline_parse` (visible ASCII `0x21..0x7E` `request-target`).
- [x] **Unconsumed / partial body handling on keep-alive connections (`server.odin`, `scanner.odin`)**:
  - Added `Request.has_consumed_body`, initialized in `validate_headers` (`te_n == 0 && clen == 0`), set to `true` in `_body_cb` when `!is_partial`, and checked directly in `response_must_close(c)` (preserving `Scanner.is_pumping` across `scanner_reset` for pipelined keep-alive requests).
  - Closed connections (`Connection: close` + `connection_close`) cleanly rather than draining when a response is sent with an unconsumed/partially-consumed body, and stopped scheduling further body reads in `_body_chunked` / `_body_length` when `c.res.state == .Sent || c.res.state == .Error`.

### Priority 3: v1 Features & Polish

- [x] **Connection upgrade / hijack API (WebSockets, etc.) (`server.odin`, `respond.odin`, `scanner.odin`, `arena.odin`, `core/websocket/server.odin`)**:
  - Added optional `on_sent: Send_Callback = nil` to `send_response_heading`/`send_heading`, made `on_send` bind `context.temp_allocator`, guard `sent > 0`, and check `.Sent`/`.Error` before invoking `on_sent` (allowing safe in-callback detach/destroy), made `connection_close` wait for `res.sends > 0`, and marked `101 Switching Protocols` as non-keep-alive in `_check_send_done`.
  - Updated `scanner_pump` to bind `context.temp_allocator`, guard re-entrant destroy/detach via `_pump_destroyed`, split allocator-switch reallocation from in-place resize, and guard `a == nil` in `_arena_block_resize_in_place`.
  - Added `connection_detach(c: ^Connection, allocator := context.allocator) -> (socket: nbio.TCP_Socket, buffered: []byte, err: runtime.Allocator_Error)` sharing `_connection_release` with `connection_destroy`, and updated `core/websocket/server.odin` onto `send_heading`, `request_set_quota`/`response_set_quota`, `response_defer`, and `connection_close`.
- [x] **Graceful server shutdown (`server.odin`)**:
  - Added `Server_Options.shutdown_timeout` (defaulting to `DEFAULT_SHUTDOWN_TIMEOUT`, `10 * time.Second`; `< 0` disables timeout) and updated `response_must_close` to return `true` when `s.shutting_down` is set.
  - Updated `_server_thread_shutdown` to cancel `curr_accept` and `curr_date`, immediately destroy idle connections (`_connection_is_idle`), tick the event loop until active connections drain or `shutdown_timeout` expires, destroy any remaining connections, and flush pending operations before releasing the event loop.
- [x] **Per-thread teardown callback (`server.odin`)**: Added `Server_Options.thread_deinitializer: proc()` invoked on each server thread in `_server_thread_shutdown` to mirror `thread_initializer` and clean up thread-local resources.
- [x] **Response `Set-Cookie` support**:
  - Ported `Cookie` and `Cookie_Same_Site` from `core/http/cookie.odin` to `http.odin` and added `set_cookie(res: ^Response, c: Cookie)` in `respond.odin` (formatting attributes onto the transaction arena and appending via `headers_add(&res.headers, "Set-Cookie", ...)`), removing the stale `// TODO: cookies` comment in `server.odin`.
- [ ] **MIME / `Content-Type` & static file/directory serving**:
  - Port `Mime_Type` and extension helpers (`mime_from_extension`, `mime_to_content_type`).
  - Automatically set `Content-Type` in `respond_file` and `respond_file_path` when not already set.
  - Add `respond_file_content` and safe `respond_dir` (with path-traversal protection and `nbio` directory handle support).
- [ ] **Convenience responders & chunked streaming**:
  - Add `respond_plain`, `respond_html`, `respond_json`.
  - Add chunked response streaming (`send_chunk` / chunked `io.Writer` integrated with `res.sends` tracking).
- [x] **Lazy `100 Continue` in `body()` (`server.odin`, `respond.odin`, `scanner.odin`)**: Moved automatic `100 Continue` sending from `on_headers` into `_body_length`/`_body_chunked` via `_maybe_send_continue` (skipping when the request is rejected before/during `body()`, has no body, or already has buffered body bytes in the scanner), made `send_continue` package-private, and removed `Server_Options.no_auto_expect_continue`.
- [x] **Move `HEAD -> GET` fallback from `server.odin` to `Router` (`server.odin`, `respond.odin`, `handlers.odin`, `router.odin`)**: Preserved `req.line.method == .Head` in `on_headers` (removing `Request.is_redirected_head`, `Server_Options.no_redirect_head_to_get`, and `logged` ternary checks), simplified `wants_body`, initialized `match.vars.allocator` on the transaction arena, and fell back to `router.routes[.Get]` when no explicit `.Head` route matches before checking `router.all`.
- [ ] **Accept error recovery & allocation-failure socket cleanup (`server.odin`)**:
  - Re-arm `thread.curr_accept = nbio.accept_poly(...)` (or back off) when `op.accept.err != nil` in `_on_accept` so a transient accept error does not permanently stop a worker thread from accepting connections.
  - Close `op.accept.client` when `xar.push(&thread.connections, ...)` fails in `_on_accept`.
- [ ] **Skip graceful close drain on dead-socket send errors (`server.odin`)**:
  - In `on_send` / `_check_send_done`, destroy the connection immediately via `connection_destroy(c)` when a send fails due to a closed/reset/broken connection instead of running `connection_close(c)`'s `nbio.shutdown` and `500ms` `CONN_CLOSE_DELAY` drain.
- [ ] **Field visibility & stale inline `TODO` cleanup (`server.odin`)**:
  - Resolve `// TODO: prive` markers on internal `Ctx` and `Response` fields and remove stale inline `TODO` comments for already-completed items (`quota option on server`, `max length`, `send quota too`).
- [ ] **`core/websocket` polish (`core/websocket/server.odin`)**:
  - **Bound per-send header memory on long-lived connections**: Avoid growing `c.transaction_arena` on every `_send_multi` (`Outgoing_Frame_Header`) over the lifetime of an upgraded connection (e.g. recycle via a per-connection freelist or free on `http.send`'s `on_sent` callback).
  - **Recycle `ws.arena` on `Ping`/`Pong` control frames**: Destroy/recycle the frame arena after `Pong` is received or after the echoed `Pong` send completes for `Ping`, instead of holding it until the next data/close frame.
  - **Enforce `GET` method in `_prepare_upgrade`**: Reject non-`GET` requests (such as `HEAD` routed via `Router`'s `.Head -> .Get` fallback or `route_all`) per RFC 6455 §4.2.1.
- [ ] **Testing, docs & package relocation**:
  - Consolidate tests into `tests/core/net/http/` (unit tests for parser, headers, router, quota; functional tests using `nbio`/`curl` for keep-alive, chunked bodies, pipelining, upgrades, range requests, and smuggling edge cases), passing under `-sanitize:address`.
  - Rewrite usage examples and overview into `doc.odin`.
  - Move `core/http2` into `core/net/http`.
