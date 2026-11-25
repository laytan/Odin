#+vet explicit-allocators
#+feature using-stmt
package http

import "base:intrinsics"
import "base:runtime"

import "core:io"
import "core:log"
import "core:net"
import "core:time"
import "core:fmt"

Handle_Proc          :: proc(ctx: ^Ctx)
Middleware_Proc      :: proc(ctx: ^Ctx, next: []Handler)
Data_Handle_Proc     :: proc(user_data: rawptr, ctx: ^Ctx)
Data_Middleware_Proc :: proc(user_data: rawptr, ctx: ^Ctx, next: []Handler)

Data_Handler :: struct {
	user_data: rawptr,
	handle:    Data_Handle_Proc,
}

Data_Middleware :: struct {
	user_data: rawptr,
	handle:    Data_Middleware_Proc,
}

Handler :: union {
	Handle_Proc,
	Middleware_Proc,
	Data_Handler,
	Data_Middleware,
}

handler_with_data :: proc "contextless" (user_data: rawptr, handle: Data_Handle_Proc) -> Handler {
	return Data_Handler{user_data = user_data, handle = handle}
}

middleware_with_data :: proc "contextless" (user_data: rawptr, handle: Data_Middleware_Proc) -> Handler {
	return Data_Middleware{user_data = user_data, handle = handle}
}

handler :: proc {
	handler_with_data,
	middleware_with_data,
}

handle :: proc(handlers: []Handler, ctx: ^Ctx) {
	if len(handlers) == 0 {
		return
	}
	rest := handlers[1:]
	switch h in handlers[0] {
	case Handle_Proc:
		assert(h != nil, "nil handler proc")
		assert(len(rest) == 0, "terminal handler cannot be followed by another handler")
		h(ctx)
	case Data_Handler:
		assert(h.handle != nil, "nil handler proc")
		assert(len(rest) == 0, "terminal handler cannot be followed by another handler")
		h.handle(h.user_data, ctx)
	case Middleware_Proc:
		assert(h != nil, "nil middleware proc")
		h(ctx, rest)
	case Data_Middleware:
		assert(h.handle != nil, "nil middleware proc")
		h.handle(h.user_data, ctx, rest)
	case nil:
		panic("nil HTTP handler")
	}
}

handler_404 :: proc(using ctx: ^Ctx) {
	res.status = .Not_Found
	respond(&res)
}

/*
A middleware that logs requests.

If no `context.logger` is set up, it is logged to stderr.

Rather than providing tons of configuration options,
you are encouraged to copy+paste the implementation allowing you to configure it exactly as wanted.
*/
logged :: proc(ctx: ^Ctx, next: []Handler) {
	Logger_Ctx :: struct {
		start: time.Time,
	}

	if _, err := context_add(ctx, Logger_Ctx{now()}); err == nil {
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
					status_string(ctx.res.status),
					ctx.res.sent,
					since(logger_ctx.start),
				)
			} else {
				context.logger.options -= {.Line, .Short_File_Path, .Long_File_Path, .Procedure}
				log.infof(
					"%v - %v %q %v.%v -> %v %m %v",
					net.endpoint_to_string(c.remote, transaction_allocator(c)),
					method_string(ctx.req.line.method),
					ctx.req.line.target,
					ctx.req.line.version.major,
					ctx.req.line.version.minor,
					status_string(ctx.res.status),
					ctx.res.sent,
					since(logger_ctx.start),
				)
			}
		})
	}

	handle(next, ctx)
}

Body_Parser_State :: struct {
	next:  []Handler,
	parts: [dynamic][]byte,
}

body_parser :: proc(ctx: ^Ctx, next: []Handler) {
	assert(len(next) > 0, "body_parser requires a non-empty next handler chain")
	s, add_err := context_add(ctx, Body_Parser_State{
		next = next,
	})
	if add_err != nil {
		invalid_request(connection_of_context(ctx), .Internal_Server_Error)
		return
	}
	s.parts.allocator = transaction_allocator(ctx)

	body(&ctx.req, on_body, retain = true)

	on_body :: proc(r: ^Request, body: []byte, is_partial: bool) {
		ctx := context_of_request(r)
		s := context_get(ctx, Body_Parser_State)
		assert(s != nil)

		if len(body) > 0 {
			if _, app_err := append(&s.parts, body); app_err != nil {
				invalid_request(connection_of_context(ctx), .Internal_Server_Error)
				return
			}
		}

		if !is_partial {
			handle(s.next, ctx)
		}
	}
}

body_parser_collect :: proc(ctx: ^Ctx, allocator := context.temp_allocator, loc := #caller_location) -> ([]byte, bool) {
	state := context_get(ctx, Body_Parser_State)
	if state == nil {
		return nil, false
	}

	overflown: bool
	n: int
	for part in state.parts {
		n, overflown = intrinsics.overflow_add(n, len(part))
		if overflown {
			return nil, false
		}
	}

	buf, err := make([]byte, n, allocator, loc)
	if err != nil {
		return nil, false
	}

	n = 0
	for part in state.parts {
		n += copy(buf[n:], part)
	}

	return buf, true
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
