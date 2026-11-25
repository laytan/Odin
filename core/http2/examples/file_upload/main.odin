// O(1)-memory streaming file upload with per-request limits and pause/resume backpressure.
//
// Run: odin run core/http2/examples/file_upload
//
// Try:
//   curl -i --data-binary @core/http2/examples/file_upload/main.odin http://127.0.0.1:8080/upload
package main

import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:sync"
import "core:time"

import http "core:http2"

@(rodata)
UPLOAD_LIMITS := http.Limits{
	max_size = 100 * mem.Megabyte,
	min      = 30 * time.Second,
	min_rate = 16 * mem.Kilobyte,
	rate_add = time.Second,
}

next_upload_id: int

Upload_State :: struct {
	file:   nbio.Handle,
	path:   string,
	offset: int,
}

main :: proc() {
	r := http.make_router()
	defer http.router_destroy(r)
	http.route_post(&r, "/upload", handle_upload)

	fmt.println("Listening on http://127.0.0.1:8080")
	s := http.make_server(http.Server_Options{handlers = {http.router(&r)}})
	err := http.listen_and_serve(&s)
	fmt.assertf(err == nil, "server error: %v", err)
}

handle_upload :: proc(ctx: ^http.Ctx) {
	http.request_set_limits(&ctx.req, &UPLOAD_LIMITS)

	id := sync.atomic_add(&next_upload_id, 1) + 1
	tmp_dir, _ := os.temp_dir(context.temp_allocator)
	path, _ := os.join_path({tmp_dir, fmt.tprintf("http2-upload-%d.bin", id)}, context.temp_allocator)

	http.context_add(ctx, Upload_State{path = path})
	nbio.open_poly(path, ctx, on_open, mode = {.Write, .Create, .Trunc})

	on_open :: proc(op: ^nbio.Operation, ctx: ^http.Ctx) {
		context.temp_allocator = http.temp_allocator(ctx)

		if op.open.err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond_plain(ctx, "failed to open upload file\n")
			return
		}

		state := http.context_get(ctx, Upload_State)
		state.file = op.open.handle
		http.response_defer(ctx, op.open.handle, proc(_: ^http.Ctx, file: nbio.Handle) {
			nbio.close(file)
		})

		http.body(ctx, on_chunk)
	}

	on_chunk :: proc(ctx: ^http.Ctx, chunk: []byte, is_partial: bool) {
		state := http.context_get(ctx, Upload_State)

		if !is_partial {
			http.respond_plain(ctx, fmt.tprintf("uploaded %d bytes to %s\n", state.offset, state.path))
			return
		}
		if len(chunk) == 0 {
			return
		}

		// With `retain = false` (default), returning from `on_chunk` lets the scanner overwrite the
		// live buffer in place. Pausing holds `chunk` valid zero-copy until `body_resume`.
		http.body_pause(ctx)
		nbio.write_poly(state.file, state.offset, chunk, ctx, on_write)
	}

	on_write :: proc(op: ^nbio.Operation, ctx: ^http.Ctx) {
		context.temp_allocator = http.temp_allocator(ctx)

		if op.write.err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond_plain(ctx, "write failed\n")
			return
		}

		state := http.context_get(ctx, Upload_State)
		state.offset += op.write.written
		http.body_resume(ctx)
	}
}
