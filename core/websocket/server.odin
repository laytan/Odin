package websocket

import "core:unicode/utf8"
import "core:log"
import "core:encoding/endian"
import "core:time"

import http "core:http2"

// Predefined (by the WebSocket RFC) status codes.
// Range `0   ..<1000` is unused.
// Range `1000..<3000` is reserved for use by the WebSocket specification.
// Range `3000..<4000` can be used by libraries, frameworks and applications and have to be registered with IANA.
// Range `4000..<5000` can be used by users for private use between endpoints that agree on a meaning.
Status :: enum u16be {
	// Indicates a normal closure, meaning that the purpose for which the connection was
	// established has been fulfilled.
	Normal = 1000,
	// Indicates that an endpoint is "going away",
	// such as a server going down or browser having navigated away from a page.
	Going_Away = 1001,
	// Indicates that an endpoint is terminating the connection due to a protocol error.
	Protocol_Error = 1002,
	// Indicates that an endpoint is terminating the connection because it has
	// received a type of data it cannot accept (e.g., an endpoint that understands only text
	// data MAY send this if it receives a binary message).
	Invalid_Type = 1003,
	// Indicates no status code was present.
	// NOTE: MUST not be set as a status code in a Close control frame by an endpoint.
	No_Status = 1005,
	// Indicates that the connection was closed abnormally, e.g., without sending or receiving
	// a Close control frame.
	// NOTE: MUST not be set as a status code in a Close control frame by an endpoint.
	Abnormal_Close = 1006,
	// Indicates that an endpoint is terminating the connection because it has received data
	// within a message that was not consistent with the type of the message.
	// (e.g., non-UTF8 data within a text message).
	Inconsistent_Data = 1007,
	// Indicates an endpoint is terminating the connection because it has received a message that
	// violates its policy. This is a generic status code when there is no other more
	// suitable status code (e.g., 1003 or 1009) or if there is a need to hide specific details
	// about the policy.
	Violates_Policy = 1008,
	// Indicates an endpoint is terminating the connection because it has received a message that
	// is too big for it to process.
	Too_Big = 1009,
	// Indicates that a client is terminating the connection because it has expected the server
	// to negotiate one or more extensions, but the server didn't return them in the response
	// message of the WebSocket handshake. The list of extensions that are needed SHOULD appear
	// in the reason part of the Close frame. Note that this status code is not used by the server,
	// because it can fail the WebSocket handshake instead.
	Insufficient_Extension_Support = 1010,
	// Indicates that a server is terminating the connection because it encountered an unexpected
	// condition that prevented it from fulfilling the request.
	Unexpected_Condition = 1011,
	// Indicates that the connection was closed due to a failure to perform a TLS handshake.
	// NOTE: MUST not be set as a status code in a Close control frame by an endpoint.
	TLS_Handshake_Failure = 1015,
}

is_valid_status :: proc(s: Status) -> bool {
	si := u16be(s)

	if si >= 3000 && si < 5000 {
		return true
	}

	#partial switch s {
	case .Normal, .Going_Away, .Protocol_Error, .Invalid_Type, .Inconsistent_Data,
		 .Violates_Policy, .Too_Big, .Insufficient_Extension_Support, .Unexpected_Condition:
		return true
	case:
		return false
	}
}

Closure :: struct #all_or_none {
	type:   Closure_Type,
	status: Status,
	reason: string,
}

Closure_Type :: enum {
	Client,
	Server,
}

Message_Type :: enum {
	Text = 1,
	Binary = 2,
}

Server :: struct {
	no_utf8_validation: bool,

	on_open:    proc(s: ^Server, c: ^http.Connection),
	on_message: proc(s: ^Server, c: ^http.Connection, type: Message_Type, message: []byte),
	on_close:   proc(s: ^Server, c: ^http.Connection, closure: Maybe(Closure)),

	user_data: rawptr,
}

// TODO: idle timeout, max message size

handler :: proc(s: ^Server) -> http.Handler {
	return http.Handler {
		user_data = s,
		handle = handle_upgrade,
	}
}

handle_upgrade :: proc(handler: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	s := (^Server)(handler.user_data)
	if !upgrade(req, res) {
		return
	}

	c := http.connection_of_response(res)

	http.context_add(&c.ctx, s)

	if s.on_open != nil {
		s.on_open(s, c)
	}

	if s.on_close != nil {
		http.response_defer(res, proc(res: ^http.Response) {
			c := http.connection_of_response(res)
			s := http.context_get(&c.ctx, ^Server)^
			closure := http.context_get(&c.ctx, Closure)
			s.on_close(s, c, closure == nil ? nil : closure^)
		})
	}

	handle_frame(c)

	handle_frame :: proc(c: ^http.Connection) {
		for {
			c.body_quota = {
				min = time.Minute,
			}
			frame_val, ok := scan_frame_or_recv(c, handle_frame)
			if !ok { return }

			prev_frame := http.context_get(&c.ctx, Frame)
			if prev_frame != nil && prev_frame.header.fin {
				prev_frame = nil
			}

			frame := http.context_add(&c.ctx, frame_val)

			log.debugf("websocket[t=%v][c=%v]: opcode=%v, fin=%v", http.td.id, c.socket, frame.header.opcode, frame.header.fin)

			switch frame.header.opcode {
			case .Binary, .Text:
				if prev_frame != nil {
					send_close(c, .Protocol_Error, "non-continuation frame while expecting a continuation")
					return
				}

				if !frame.header.fin {
					break
				}

				s := http.context_get(&c.ctx, ^Server)^

				if frame.header.opcode == .Text && !s.no_utf8_validation && !utf8.valid_string(string(frame.payload_data)) {
					send_close(c, .Inconsistent_Data, "Invalid UTF-8 text")
					return
				}

				assert(s.on_message != nil, "no message handler set")
				s.on_message(s, c, Message_Type(frame.header.opcode), frame.payload_data)

			case .Continuation:
				head: ^Frame
				head_idx: int
				#reverse for var, i in c.ctx.vars {
					(var.id == Frame) or_continue
					var_frame := (^Frame)(var.val)
					if var_frame.header.opcode != .Continuation && var_frame.header.fin {
						head = var_frame
						head_idx = i
						break
					}
				}

				if head == nil {
					send_close(c, .Protocol_Error, "Continuation frame while no message is in progress")
					return
				}
				assert(head.header.opcode == .Text || head.header.opcode == .Binary)

				if !frame.header.fin {
					break
				}

				size := len(head.payload_data)
				for var in c.ctx.vars[head_idx+1:] {
					(var.id == Frame) or_continue
					var_frame := (^Frame)(var.val)
					assert(var_frame.header.opcode == .Continuation)
					size += len(var_frame.payload_data)
				}

				message, err := make([]byte, size, http.connection_allocator(c))
				if err != nil {
					send_close(c, .Too_Big, "message size too big")
					return
				}

				n := 0
				for var, i in c.ctx.vars[head_idx:] {
					assert(i != 0 || var.val == head)
					(var.id == Frame) or_continue
					var_frame := (^Frame)(var.val)
					n += copy(message, var_frame.payload_data)
				}
				assert(n == size)

				s := http.context_get(&c.ctx, ^Server)^

				if head.header.opcode == .Text && !s.no_utf8_validation && !utf8.valid_string(string(message)) {
					send_close(c, .Inconsistent_Data, "Invalid UTF-8 text")
					return
				}

				assert(s.on_message != nil, "no message handler set")
				s.on_message(s, c, Message_Type(head.header.opcode), message)

			case .Ping:
				send(c, .Pong, frame.payload_data)

			case .Pong:
				// TODO: update idle timeout.

			case .Close:
				status := Status.No_Status
				reason: string
				if frame.payload_len >= 2 {
					status = Status(endian.unchecked_get_u16be(frame.payload_data))
					reason = string(frame.payload_data[2:])

					if !is_valid_status(status) {
						send_close(c, .Protocol_Error, "invalid close status code")
						return
					}
				}

				s := http.context_get(&c.ctx, ^Server)^

				if !s.no_utf8_validation && !utf8.valid_string(reason) {
					send_close(c, .Inconsistent_Data, "close frame with invalid UTF-8 reason")
					return
				}

				closure := http.context_get(&c.ctx, Closure)
				if closure == nil {
					http.context_add(&c.ctx, Closure{
						type   = .Client,
						status = status,
						reason = reason,
					})
					_send(c, .Close, frame.payload_data)
				}

				http.set_header(&c.res, "Connection", "close")
				http.respond(&c.res)
			}
		}
	}
}

send_close :: proc(c: ^http.Connection, status: Status, reason: string) {
	http.context_add(&c.ctx, Closure{
		type   = .Server,
		status = status,
		reason = reason,
	})
	log.warn("unimplemented")
}

send_message :: proc(c: ^http.Connection, type: Message_Type, data: []byte) {
	_send(c, Opcode(type), data)
}

_send :: proc(c: ^http.Connection, opcode: Opcode, data: []byte, fin := true) {
	Outgoing_Frame_Header :: struct {
		header: Frame_Header,
		len:    struct #raw_union {
			len_8_bytes: u64be,
			len_2_bytes: u16be,
		},
	}
	f := http.context_add(&c.ctx, Outgoing_Frame_Header{
		header = {
			opcode = opcode,
			fin    = fin,
		},
	})

	length := size_of(Frame_Header)
	switch {
	case len(data) > int(max(u16)):
		f.header.hpayload_len = LEN_8_BYTES
		length += size_of(u64)
		f.len.len_8_bytes = u64be(len(data))
	case len(data) > 125:
		f.header.hpayload_len = LEN_2_BYTES
		length += size_of(u16)
		f.len.len_2_bytes = u16be(len(data))
	case:
		f.header.hpayload_len = u8(len(data))
	}

	log.debugf("websocket[t=%v][c=%v]: opcode=%v, len=%v, fin=%v", http.td.id, c.socket, opcode, len(data), fin)

	header_bytes := ([^]byte)(f)[:length]
	http.send(&c.res, {header_bytes, data})
}
