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
import "core:terminal"
import "core:time"

import http "core:http2"

next_worker_id: int

// Per-server-thread state initialized in `thread_initializer` and cleaned up in `thread_deinitializer`.
// Each server thread runs its own event loop, so thread-local resources need no mutex.
@(thread_local)
worker_id: int
@(thread_local)
worker_requests: int

Slow_Req :: struct {
	ctx:   ^http.Ctx,
	timer: ^nbio.Operation,
}

main :: proc() {
	r := http.make_router()
	defer http.router_destroy(r)
	http.route_get(&r, "/", handle_fast)
	http.route_get(&r, "/slow", handle_slow)

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 8080,
		thread_count = 2,
		handlers     = {http.router(&r)},
		thread_initializer = proc() {
			worker_id = sync.atomic_add(&next_worker_id, 1) + 1
			fmt.printfln("worker %d started", worker_id)
		},
		thread_deinitializer = proc() {
			fmt.printfln("worker %d stopping (served %d requests)", worker_id, worker_requests)
		},
	})

	terminal.set_termination_handler(proc "contextless" (server: rawptr) -> bool {
		return http.server_shutdown_async((^http.Server)(server))
	}, &server)

	fmt.println("Listening on http://127.0.0.1:8080 (press Ctrl-C to stop)")
	err := http.listen_and_serve(&server)
	fmt.assertf(err == nil, "server error: %v", err)
	fmt.println("Shutdown complete")
}

handle_fast :: proc(ctx: ^http.Ctx) {
	worker_requests += 1
	http.respond_plain(ctx, fmt.tprintf("served by worker %d (total=%d)\n", worker_id, worker_requests))
}

handle_slow :: proc(ctx: ^http.Ctx) {
	worker_requests += 1
	req := new_clone(Slow_Req{ctx = ctx}, http.transaction_allocator(ctx))
	http.response_defer(ctx, req, proc(_: ^http.Ctx, req: ^Slow_Req) {
		nbio.remove(req.timer)
	})

	req.timer = nbio.timeout_poly(5 * time.Second, req, proc(_: ^nbio.Operation, req: ^Slow_Req) {
		context.temp_allocator = http.temp_allocator(req.ctx)
		req.timer = nil
		http.respond_plain(req.ctx, fmt.tprintf("slow request drained cleanly on worker %d\n", worker_id))
	})
}
