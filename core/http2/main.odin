#+vet explicit-allocators
package http

import "core:fmt"
import "core:os"
import "core:terminal"

/*
Serves the current working directory.

You can run this with `odin run $(odin root)/core/http` from anywhere to serve some files.
*/
@(private)
main :: proc() {
	port := DEFAULT_PORT
	if len(os.args) > 1 {
		ok: bool
		port, ok = parse_int(os.args[1])
		if !ok {
			fmt.eprintfln("invalid port: %v", os.args[1])
			os.exit(1)
		}
	}

	server := make_server({
		handlers = {logged, serve_pwd},
		port     = port,
	}, context.allocator)

	terminal.set_termination_handler(proc "contextless" (server: rawptr) -> bool {
		return server_shutdown_async((^Server)(server))
	}, &server)

	fmt.printfln("Serving on http://172.0.0.1:%v", port)
	err := listen_and_serve(&server)
	if err != nil {
		fmt.eprintfln("Error serving: %v", err)
		os.exit(1)
	}

	serve_pwd :: proc(ctx: ^Ctx) {
		target := route_target(ctx)
		if target == "" {
			ctx.res.status = .Not_Found
			respond(ctx)
			return
		}

		respond_dir(ctx, "", target)
	}
}
