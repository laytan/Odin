// Static file serving with Range/If-Range support, embedded #load assets, and manual file handles.
//
// Run: cd core/http2/examples/static_files && odin run .
//
// Try:
//   curl -i -H "Range: bytes=0-31" http://127.0.0.1:8080/embedded
//   curl -i -H "Range: bytes=0-31" -H 'If-Range: "v1"' http://127.0.0.1:8080/embedded
//   curl -i -H "Range: bytes=0-31" http://127.0.0.1:8080/no-range
//   curl -i http://127.0.0.1:8080/manual
//   curl -i http://127.0.0.1:8080/files/main.odin
package main

import "core:fmt"
import "core:os"

import http "core:http2"

SELF_SRC :: #load("main.odin")

main :: proc() {
	r := http.make_router()

	http.route_get(&r, "/", proc(ctx: ^http.Ctx) {
		http.respond_html(&ctx.res, `<ul>
<li><a href="/embedded">/embedded</a></li>
<li><a href="/no-range">/no-range</a></li>
<li><a href="/manual">/manual</a></li>
<li><a href="/files/main.odin">/files/main.odin</a></li>
</ul>`)
	})

	http.route_get(&r, "/embedded", proc(ctx: ^http.Ctx) {
		// Explicitly overwrite content-type, by default it is inferred from the given file.
		http.set_header(&ctx.res, "Content-Type", "text/plain; charset=utf-8")
		// Setting an ETag before responding has the response support and handle the ETag condition.
		http.set_header(&ctx.res, "ETag", `"v1"`)
		http.respond_file_content(&ctx.res, "main.odin", SELF_SRC)
	})

	http.route_get(&r, "/no-range", proc(ctx: ^http.Ctx) {
		// Explicitly opt-out of range request by setting it to none before responding.
		http.set_header(&ctx.res, "Accept-Ranges", "none")
		http.respond_file_path(&ctx.res, "main.odin")
	})

	http.route_get(&r, "/manual", proc(ctx: ^http.Ctx) {
		// `.Non_Blocking` is required by `nbio.associate_handle` on Windows (`FILE_FLAG_OVERLAPPED`).
		// Or use `nbio.open()` to open an nbio file directly.
		f, err := os.open("main.odin", {.Read, .Non_Blocking})
		if err != nil {
			ctx.res.status = .Not_Found
			http.respond_plain(&ctx.res, "not found\n")
			return
		}

		// Defer mechanism for after the response is sent, instead of after the procedure returns.
		// Combining with the context system we can make sure the file is always closed.
		http.context_add(ctx, f)
		http.response_defer(ctx, proc(ctx: ^http.Ctx) {
			os.close(http.context_get(ctx, ^os.File)^)
		})

		assoc_err := http.respond_file(&ctx.res, f)
		assert(assoc_err == nil, "failed to associate file with the event loop, shouldn't be possible here")
	})

	// Serves the current working directory at /files
	http.route_get(&r, "/files/*", proc(ctx: ^http.Ctx) {
		http.respond_dir(&ctx.res, ".", http.route_suffix(ctx))
	})

	fmt.println("Listening on http://127.0.0.1:8080")
	s := http.make_server(http.Server_Options{handlers = {http.router(&r)}})
	err := http.listen_and_serve(&s)
	fmt.assertf(err == nil, "server error: %v", err)
}
