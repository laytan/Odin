package websocket

import "base:intrinsics"

import "core:unicode/utf8"
import "core:log"
import "core:encoding/endian"
import "core:time"

import http "core:http2"

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
	idle_timeout:       time.Duration,
	max_message_size:   int,

	on_open:    proc(s: ^Server, c: ^http.Connection),
	on_message: proc(s: ^Server, c: ^http.Connection, type: Message_Type, message: []byte),
	on_close:   proc(s: ^Server, c: ^http.Connection, closure: Maybe(Closure)),

	user_data: rawptr,
}

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
		s := http.context_get(&c.ctx, ^Server)^

		for {
			head: ^Frame
			head_idx: int
			size: int
			#reverse for var, i in c.ctx.vars {
				(var.id == Frame) or_continue
				var_frame := (^Frame)(var.val)
				if var_frame.header.opcode == .Continuation {
					size += len(var_frame.payload_data)
				}
				if var_frame.header.opcode != .Continuation {
					if var_frame.header.fin { break }
					if var_frame.header.opcode != .Text && var_frame.header.opcode != .Binary { break }
					head = var_frame
					head_idx = i
					size += len(var_frame.payload_data)
					break
				}
			}

			max_size := s.max_message_size
			if max_size <= 0 {
				max_size = -1
			} else {
				max_size = max(0, max_size-size)
			}

			frame_val, scan_res := scan_frame_or_recv(c, max_size, s.idle_timeout, handle_frame)
			switch scan_res {
			case .Ok:
			case .Needs_Recv:        unreachable()
			case .Will_Callback:     return
			case .Max_Size_Exceeded: send_close(c, .Too_Big, "message size too big"); continue
			case:                    unreachable()
			}

			frame := http.context_add(&c.ctx, frame_val)

			size += len(frame.payload_data)

			log.debugf("websocket[t=%v][c=%v]: opcode=%v, fin=%v", http.td.id, c.socket, frame.header.opcode, frame.header.fin)

			switch frame.header.opcode {
			case .Binary, .Text:
				if head != nil {
					send_close(c, .Protocol_Error, "non-continuation frame while expecting a continuation")
					continue
				}

				if !frame.header.fin {
					continue
				}

				if frame.header.opcode == .Text && !s.no_utf8_validation && !utf8.valid_string(string(frame.payload_data)) {
					send_close(c, .Inconsistent_Data, "Invalid UTF-8 text")
					continue
				}

				assert(s.on_message != nil, "no message handler set")
				s.on_message(s, c, Message_Type(frame.header.opcode), frame.payload_data)

			case .Continuation:
				if head == nil {
					send_close(c, .Protocol_Error, "Continuation frame while no message is in progress")
					continue
				}

				if !frame.header.fin {
					continue
				}

				message, err := make([]byte, size, http.connection_allocator(c))
				if err != nil {
					send_close(c, .Too_Big, "out of memory")
					continue
				}

				n := 0
				for var, i in c.ctx.vars[head_idx:] {
					assert(i != 0 || var.val == head)
					(var.id == Frame) or_continue
					var_frame := (^Frame)(var.val)
					n += copy(message, var_frame.payload_data)
				}
				assert(n == size)

				if head.header.opcode == .Text && !s.no_utf8_validation && !utf8.valid_string(string(message)) {
					send_close(c, .Inconsistent_Data, "Invalid UTF-8 text")
					continue
				}

				assert(s.on_message != nil, "no message handler set")
				s.on_message(s, c, Message_Type(head.header.opcode), message)

			case .Ping:
				_send(c, .Pong, frame.payload_data)

			case .Pong:

			case .Close:
				status := Status.No_Status
				reason: string
				if frame.payload_len >= 2 {
					status = Status(endian.unchecked_get_u16be(frame.payload_data))
					reason = string(frame.payload_data[2:])

					if !is_valid_status(status) {
						send_close(c, .Protocol_Error, "invalid close status code")
						continue
					}
				}

				if !s.no_utf8_validation && !utf8.valid_string(reason) {
					send_close(c, .Inconsistent_Data, "close frame with invalid UTF-8 reason")
					continue
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
				return
			}
		}
	}
}

send_close :: proc(c: ^http.Connection, status: Status, reason: string) {
	closure := http.context_add(&c.ctx, Closure{
		type   = .Server,
		status = status,
		reason = reason,
	})

	log.debugf("websocket[t=%v][c=%v]: status=%v, reason=%q", status, reason)

	if status == .Too_Big {
		s := http.context_get(&c.ctx, ^Server)^
		log.infof("websocket[t=%v][c=%v]: msg=\"max message size exceeded\", max=%v", s.max_message_size)
	}

	#assert(intrinsics.type_core_type(Status) == u16be)
	status_bytes := ([^]byte)(&closure.status)[:size_of(Status)]

	_send_multi(c, .Close, {status_bytes, transmute([]byte)reason})
}

send_message :: proc(c: ^http.Connection, type: Message_Type, data: []byte) {
	_send(c, Opcode(type), data)
}

_send :: proc(c: ^http.Connection, opcode: Opcode, data: []byte, fin := true) {
	_send_multi(c, opcode, {data}, fin)
}

_send_multi :: proc(c: ^http.Connection, opcode: Opcode, data: [][]byte, fin := true) {
	Outgoing_Frame_Header :: struct {
		header: Frame_Header,
		len:    struct #raw_union {
			len_8_bytes: u64be,
			len_2_bytes: u16be,
		},
	}
	f := new_clone(Outgoing_Frame_Header{
		header = {
			opcode = opcode,
			fin    = fin,
		},
	}, http.connection_allocator(c))

	data_len := 0
	for buf in data { data_len += len(buf) }

	length := size_of(Frame_Header)
	switch {
	case data_len > int(max(u16)):
		f.header.hpayload_len = LEN_8_BYTES
		length += size_of(u64)
		f.len.len_8_bytes = u64be(data_len)
	case data_len > 125:
		f.header.hpayload_len = LEN_2_BYTES
		length += size_of(u16)
		f.len.len_2_bytes = u16be(data_len)
	case:
		f.header.hpayload_len = u8(data_len)
	}

	log.debugf("websocket[t=%v][c=%v]: opcode=%v, len=%v, fin=%v", http.td.id, c.socket, opcode, data_len, fin)

	bufs := ([^][]byte)(intrinsics.alloca(size_of([]byte)*(len(data)+1), align_of([]byte)))[:len(data)+1]
	bufs[0] = ([^]byte)(f)[:length]
	copy(bufs[1:], data)

	http.send(&c.res, bufs)
}
