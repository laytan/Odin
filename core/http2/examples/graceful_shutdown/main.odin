// Graceful shutdown on Ctrl-C / SIGTERM with per-thread lifecycle hooks and in-flight request draining.
//
// Run: odin run core/http2/examples/graceful_shutdown
//
// Try:
//   curl -i http://127.0.0.1:8080/
//   curl -i http://127.0.0.1:8080/slow   # then press Ctrl-C; /slow completes before the server exits
package main

import "core:fmt"
import "core:nbio"
import "core:sync"
import "core:time"

import "core:c/libc"
import win "core:sys/windows"

import http "core:http2"

server: http.Server
next_worker_id: int

// Per-server-thread state initialized in `thread_initializer` and cleaned up in `thread_deinitializer`.
// Each server thread runs its own event loop, so thread-local resources need no mutex.
@(thread_local)
worker_id: int
@(thread_local)
worker_requests: int

Slow_State :: struct {
	timer: ^nbio.Operation,
}

main :: proc() {
	r := http.make_router()
	defer http.router_destroy(r)
	http.route_get(&r, "/", handle_fast)
	http.route_get(&r, "/slow", handle_slow)

	when ODIN_OS == .Windows {
		// Satisfy -vet
		_ :: libc

		win.SetConsoleCtrlHandler(proc "system" (_: win.DWORD) -> win.BOOL {
			return win.BOOL(http.server_shutdown_async(&server))
		}, win.TRUE)
	} else {
		// Satisfy -vet
		_ :: win

		// `server_shutdown_async` is contextless and async-signal-safe; a second signal restores the
		// default handler to force-exit immediately.
		on_signal :: proc "c" (sig: libc.int) {
			if !http.server_shutdown_async(&server) {
				libc.signal(sig, cast(proc "c" (libc.int))libc.SIG_DFL)
				libc.raise(sig)
			}
		}
		libc.signal(libc.SIGINT, on_signal)
		libc.signal(libc.SIGTERM, on_signal)
	}

	server = http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 8080,
		thread_count = 2,
		handler      = http.router(&r),
		thread_initializer = proc() {
			worker_id = sync.atomic_add(&next_worker_id, 1) + 1
			fmt.printfln("worker %d started", worker_id)
		},
		thread_deinitializer = proc() {
			fmt.printfln("worker %d stopping (served %d requests)", worker_id, worker_requests)
		},
	})

	fmt.println("Listening on http://127.0.0.1:8080 (press Ctrl-C to stop)")
	err := http.listen_and_serve(&server)
	fmt.assertf(err == nil, "server error: %v", err)
	fmt.println("Shutdown complete")
}

handle_fast :: proc(ctx: ^http.Ctx) {
	worker_requests += 1
	http.respond_plain(&ctx.res, fmt.tprintf("served by worker %d (total=%d)\n", worker_id, worker_requests))
}

handle_slow :: proc(ctx: ^http.Ctx) {
	worker_requests += 1
	state := http.context_add(ctx, Slow_State{})
	http.response_defer(ctx, proc(ctx: ^http.Ctx) {
		state := http.context_get(ctx, Slow_State)
		if state.timer != nil {
			nbio.remove(state.timer)
			state.timer = nil
		}
	})

	state.timer = nbio.timeout_poly(5 * time.Second, ctx, proc(_: ^nbio.Operation, ctx: ^http.Ctx) {
		context.temp_allocator = http.temp_allocator(ctx)
		state := http.context_get(ctx, Slow_State)
		state.timer = nil
		http.respond_plain(&ctx.res, fmt.tprintf("slow request drained cleanly on worker %d\n", worker_id))
	})
}
