#+vet explicit-allocators
#+feature using-stmt
package http

import "base:runtime"

import "core:log"
import "core:net"
import "core:strings"
import "core:time"
import "core:fmt"

Handler_Proc :: proc(handler: ^Handler, ctx: ^Ctx)
Handle_Proc  :: proc(ctx: ^Ctx)

Handler :: struct {
	user_data: rawptr,
	next:      ^Handler,
	handle:    Handler_Proc,
}

handler :: proc "contextless" (handle: Handle_Proc) -> Handler {
	h: Handler
	h.user_data = rawptr(handle)

	handle := proc(h: ^Handler, ctx: ^Ctx) {
		p := (Handle_Proc)(h.user_data)
		p(ctx)
	}

	h.handle = handle
	return h
}

handler_404 :: proc(using ctx: ^Ctx) {
	res.status = .Not_Found
	respond(&res)
}

middleware_proc :: proc(next: ^Handler, handle: Handler_Proc) -> Handler {
	h: Handler
	h.next = next
	h.handle = handle
	return h
}

/*
A middleware that logs requests.

If no `context.logger` is set up, it is logged to stderr.

Rather than providing tons of configuration options,
you are encouraged to copy+paste the implementation allowing you to configure it exactly as wanted.
*/
logged :: proc(next: ^Handler) -> Handler {
	return middleware_proc(next, logger)

	logger :: proc(h: ^Handler, ctx: ^Ctx) {
		Logger_Ctx :: struct {
			start: time.Time,
		}

		context_add(ctx, Logger_Ctx{now()})

		response_defer(ctx, proc(ctx: ^Ctx) {
			c          := connection_of_context(ctx)
			logger_ctx := context_get(ctx, Logger_Ctx)

			if context.logger.procedure == runtime.default_logger_proc {
				date: [DATE_LENGTH]byte
				date_write(date[:], now())
				fmt.eprintfln(
					"[%v] %v - %v %q %v.%v -> %v %m %v",
					string(date[:]),
					net.address_to_string(c.remote.address, transaction_allocator(c)),
					method_string(.Head if ctx.req.is_redirected_head else ctx.req.line.method),
					ctx.req.line.target,
					ctx.req.line.version.major,
					ctx.req.line.version.minor,
					strings.trim_right_space(status_string(ctx.res.status)),
					ctx.res.sent,
					since(logger_ctx.start),
				)
			} else {
				context.logger.options -= {.Line, .Short_File_Path, .Long_File_Path, .Procedure}
				log.infof(
					"%v - %v %q %v.%v -> %v %m %v",
					net.address_to_string(c.remote.address, transaction_allocator(c)),
					method_string(.Head if ctx.req.is_redirected_head else ctx.req.line.method),
					ctx.req.line.target,
					ctx.req.line.version.major,
					ctx.req.line.version.minor,
					strings.trim_right_space(status_string(ctx.res.status)),
					ctx.res.sent,
					since(logger_ctx.start),
				)
			}
		})

		h.next.handle(h.next, ctx)
	}
}

