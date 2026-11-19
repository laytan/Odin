#+vet explicit-allocators
#+feature using-stmt
package http

import "base:runtime"

import "core:io"
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
					net.endpoint_to_string(c.remote, transaction_allocator(c)),
					method_string(ctx.req.line.method),
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
					method_string(ctx.req.line.method),
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

Body_Parser_State :: struct {
	h:     ^Handler,
	parts: [dynamic][]byte,
}

body_parser :: proc(next: ^Handler) -> Handler {
	return {
		next   = next,
		handle = proc(h: ^Handler, ctx: ^Ctx) {
			assert(context_get(ctx, Body_Parser_State) == nil)
			s := context_add(ctx, Body_Parser_State{
				h = h,
			})
			s.parts.allocator = transaction_allocator(ctx)

			body(&ctx.req, on_body)

			on_body :: proc(r: ^Request, body: []byte, is_partial: bool) {
				ctx := context_of_request(r)
				s := context_get(ctx, Body_Parser_State)
				assert(s != nil)

				if len(body) > 0 {
					append(&s.parts, body)
				}

				if !is_partial {
					s.h.next.handle(s.h.next, ctx)
				}
			}
		},
	}
}

Body_Parser_Iterator :: struct {
	state: ^Body_Parser_State,
	i:     int,
}

body_parser_iterator :: proc(ctx: ^Ctx) -> Body_Parser_Iterator {
	return {
		state = context_get(ctx, Body_Parser_State),
		i     = 0,
	}
}

body_parser_iter :: proc(s: ^Body_Parser_Iterator) -> ([]byte, int, bool) {
	if len(s.state.parts) <= s.i {
		return nil, 0, false
	}

	defer s.i += 1
	part := s.state.parts[s.i]
	return part, s.i, true
}

Body_Parser_Stream :: struct {
	state: ^Body_Parser_State,
	off:   i64,
}

body_parser_stream_init :: proc(s: ^Body_Parser_Stream, ctx: ^Ctx) {
	s.state = context_get(ctx, Body_Parser_State)
	assert(s.state != nil)
	s.off = 0
}

body_parser_stream :: proc(s: ^Body_Parser_Stream) -> io.Stream {
	return {
		data = s,
		procedure = proc(s: rawptr, mode: io.Stream_Mode, buf: []byte, off: i64, from: io.Seek_From) -> (i64, io.Error) {
			s := (^Body_Parser_Stream)(s)

			switch mode {
			case .Read:
				n, err := read_at(s, buf, s.off)
				s.off += n
				return n, err

			case .Read_At:
				return read_at(s, buf, off)

			case .Seek:
				switch from {
				case .Start:
					s.off = off
				case .Current:
					s.off += off
				case .End:
					size: i64
					for part in s.state.parts {
						size += i64(len(part))
					}
					s.off = size-off
				case:
					return 0, .Invalid_Whence
				}

				return s.off, nil

			case .Size:
				size: i64
				for part in s.state.parts {
					size += i64(len(part))
				}
				return size, nil

			case .Query:
				return io.query_utility({.Read, .Read_At, .Seek, .Size, .Query})

			case .Close, .Flush, .Write, .Write_At, .Destroy:
				return 0, .Unsupported

			case:
				return 0, .Unsupported
			}

			read_at :: proc(s: ^Body_Parser_Stream, buf: []byte, off: i64) -> (i64, io.Error) {
				if len(buf) == 0 {
					return 0, nil
				}
				if off < 0 {
					return 0, .Invalid_Offset
				}

				curr: i64
				start_idx: int
				start_part := -1
				for part, i in s.state.parts {
					if curr + i64(len(part)) > off {
						start_part = i
						start_idx  = int(off - curr)
						break
					}

					curr += i64(len(part))
				}

				if start_part == -1 {
					if off == curr {
						return 0, .EOF
					}
					return 0, .Invalid_Offset
				}

				n := copy(buf, s.state.parts[start_part][start_idx:])
				if n < len(buf) {
					for part in s.state.parts[start_part+1:] {
						n += copy(buf[n:], part)
						if n == len(buf) { break }
					}
				}

				return i64(n), nil
			}
		},
	}
}
