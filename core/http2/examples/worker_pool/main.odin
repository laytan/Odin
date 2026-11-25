// Offloading blocking or CPU-heavy work to a thread pool without stalling the nbio event loop.
//
// Run: odin run core/http2/examples/worker_pool
//
// Try:
//   curl -i http://127.0.0.1:8080/ping
//   curl -i http://127.0.0.1:8080/work/500
package main

import "core:fmt"
import "core:nbio"
import "core:thread"
import "core:time"

import http "core:http2"

pool: thread.Pool

Job :: struct {
	ctx:    ^http.Ctx,
	loop:   ^nbio.Event_Loop,
	ms:     int,
	result: string,
}

main :: proc() {
	thread.pool_init(&pool, context.allocator, 4)
	thread.pool_start(&pool)
	defer thread.pool_finish(&pool)

	r := http.make_router()
	http.route_get(&r, "/ping", proc(ctx: ^http.Ctx) {
		http.respond_plain(&ctx.res, "pong\n")
	})
	http.route_get(&r, "/work/:ms", handle_work)

	fmt.println("Listening on http://127.0.0.1:8080")
	s := http.make_server(http.Server_Options{handlers = {http.router(&r)}})
	err := http.listen_and_serve(&s)
	fmt.assertf(err == nil, "server error: %v", err)
}

handle_work :: proc(ctx: ^http.Ctx) {
	ms, ok := http.route_param_int(http.route_params(ctx), "ms")
	if !ok {
		ctx.res.status = .Bad_Request
		http.respond_plain(&ctx.res, "expected integer milliseconds\n")
		return
	}

	// `thread.Pool` keeps completed tasks in `tasks_done` until popped; drain them so memory stays bounded.
	for _ in thread.pool_pop_done(&pool) {}

	job := http.context_add(ctx, Job{
		ctx  = ctx,
		loop = nbio.current_thread_event_loop(),
		ms   = clamp(ms, 1, 5000),
	})
	thread.pool_add_task(&pool, context.allocator, worker_task, job)
}

worker_task :: proc(task: thread.Task) {
	job := (^Job)(task.data)
	// Cross-thread contract: while only one thread touches the connection at a time, worker threads may
	// read request state and allocate on its arenas, but `nbio`-bound calls (`respond*`, `send*`, `body`,
	// `connection_close`) must be posted back to the owning server thread's event loop.
	context.temp_allocator = http.temp_allocator(job.ctx)

	time.sleep(time.Duration(job.ms) * time.Millisecond)

	job.result = fmt.tprintf("finished %dms job on worker thread\n", job.ms)
	nbio.next_tick_poly(job, on_done, l = job.loop)

	on_done :: proc(_: ^nbio.Operation, job: ^Job) {
		// Raw `nbio` callbacks run with the thread's tick-scoped temp allocator, so rebind it to the connection.
		context.temp_allocator = http.temp_allocator(job.ctx)
		http.respond_plain(&job.ctx.res, job.result)
	}
}
