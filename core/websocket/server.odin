package websocket

import "base:intrinsics"

import "core:crypto/hash"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:log"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

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
	arena:  ^http.Arena,
}

Closure_Type :: enum {
	Client,
	Server,
}

Message_Type :: enum {
	Text = 1,
	Binary = 2,
}

Message :: struct {
	type:  Message_Type,
	data:  []byte,
	arena: ^http.Arena,
}

Server :: struct {
	// The spec mandates all `.Text` message types to have their UTF-8 encoding validated.
	// This option can be used to bypass that, which might help with performance on large text messages.
	no_utf8_validation: bool,
	// Time that a connection is allowed to be idle.
	// Zero means no timeout.
	idle_timeout:       time.Duration,
	// The maximum size of a message, this is without the header size.
	max_message_size:   int,

	// Called after the WebSocket handshake has been done and messages can start to be sent.
	on_open:    proc(s: ^Server, c: ^http.Connection),
	on_message: proc(s: ^Server, c: ^http.Connection, message: Message),
	// Called when the connection is either gracefully or abruptly closed.
	// Guaranteed to be called in any situation for every connection.
	// `closure` is `nil` if the close was not done through the WebSocket protocol (abrupt close for example).
	on_close:   proc(s: ^Server, c: ^http.Connection, closure: Maybe(Closure)),

	user_data: rawptr,
}

/*
A HTTP handler that handles upgrade requests, adding upgraded connections to the server.
*/
handler :: proc(s: ^Server) -> http.Handler {
	return http.Handler {
		user_data = s,
		handle = proc(handler: ^http.Handler, req: ^http.Request, res: ^http.Response) {
			s := (^Server)(handler.user_data)
			if !_upgrade(req, res) {
				return
			}

			c := http.connection_of_response(res)
			_serve_connection(s, c)
		},
	}
}

/*
Immediately close a connection without a WebSocket handshake.

Usually used for protocol errors, when a handshake wouldn't work anymore.

Note that the HTTP layer still shuts down the socket and waits a bit before closing the socket.
*/
immediately_close :: proc(c: ^http.Connection, status: Status, reason: string) {
	send_close(c, status, reason)
	http.set_header(&c.res, "Connection", "close")
	http.respond(&c.res)
}

/*
Sends a close message to the client.

The client is expected to acknowledge the closure to the server, after which the connection is closed.
*/
send_close :: proc(c: ^http.Connection, status: Status, reason: string) {
	ws := http.context_get(&c.ctx, Connection)
	if ws.closure != nil {
		return
	}

	ws.closure = Closure{
		type   = .Server,
		status = status,
		reason = reason,
		arena  = nil,
	}
	closure := &ws.closure.(Closure)

	log.debugf("websocket[t=%v][c=%v]: status=%v, reason=%q", http.td.id, c.socket, status, reason)

	if status == .Too_Big {
		log.infof("websocket[t=%v][c=%v]: msg=\"max message size exceeded\", max=%v", http.td.id, c.socket, ws.s.max_message_size)
	}

	#assert(intrinsics.type_core_type(Status) == u16be)
	status_bytes := ([^]byte)(&closure.status)[:size_of(Status)]

	_send_multi(c, .Close, {status_bytes, transmute([]byte)reason})
}

/*
Send a message to the client.
*/
send :: proc(c: ^http.Connection, type: Message_Type, data: []byte) {
	_send(c, _Opcode(type), data)
}

@(rodata)
_GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

_Opcode :: enum u8 {
	Continuation,
	Text,
	Binary,
	Close = 8,
	Ping,
	Pong,
}

_Frame_Header :: bit_field u16 {
	opcode:       _Opcode | 4,
	rsv3:         bool    | 1,
	rsv2:         bool    | 1,
	rsv1:         bool    | 1,
	fin:          bool    | 1,
	hpayload_len: u8      | 7,
	masked:       bool    | 1,
}

_Frame :: struct {
	header:       _Frame_Header,
	payload_len:  u64,
	payload_data: []byte,
}

_Mask :: [4]byte

// Magic frame header length indicates length of payload is the following 2 bytes (as a u16be).
_LEN_2_BYTES :: 126

// Magic frame header length indicates length of payload is the following 8 bytes (as a u64be).
_LEN_8_BYTES :: 127

_prepare_upgrade :: proc(req: ^http.Request, res: ^http.Response) -> bool {
	res.status = .Bad_Request

	upgrade, has_upgrade := http.get_header(req, "Upgrade")
	if !has_upgrade {
		return false
	}

	if !strings.equal_fold(upgrade, "websocket") {
		return false
	}

	connection, _ := http.get_header(req, "Connection")
	if !strings.equal_fold(connection, "upgrade") {
		return false
	}

	version, _ := http.get_header(req, "Sec-WebSocket-Version")
	if version != "13" {
		http.set_header(res, "Sec-WebSocket-Version", "13")
		return false
	}

	key, _ := http.get_header(req, "Sec-WebSocket-Key")
	if base64.decoded_len(key) != 16 {
		return false
	}

	{
		ctx: hash.Context
		hash.init(&ctx, .Insecure_SHA1)
		hash.update(&ctx, transmute([]byte)key)
		hash.update(&ctx, transmute([]byte)_GUID)

		accept_hash: [sha1.DIGEST_SIZE]byte
		hash.final(&ctx, accept_hash[:])

		accept := base64.encode(accept_hash[:], allocator=context.temp_allocator)
		http.set_header(res, "Sec-WebSocket-Accept", accept)
	}

	http.set_header(res, "Upgrade", "websocket")
	http.set_header(res, "Connection", "upgrade")
	res.status = .Switching_Protocols
	return true
}

_upgrade :: proc(req: ^http.Request, res: ^http.Response) -> bool {
	ok := _prepare_upgrade(req, res)
	if !ok {
		http.respond(res)
	} else {
		http.send_heading(res)
	}
	return ok
}

Connection :: struct {
	s:       ^Server,
	closure: Maybe(Closure),
	frames:  [dynamic]_Frame,
	arena:   ^http.Arena,
}

_serve_connection :: proc(s: ^Server, c: ^http.Connection) {
	ws := http.context_add(&c.ctx, Connection{
		s     = s,
	})
	ws.frames.allocator = http.transaction_allocator(c)

	if s.on_close != nil {
		http.response_defer(&c.res, proc(res: ^http.Response) {
			c  := http.connection_of_response(res)
			ws := http.context_get(&c.ctx, Connection)
			ws.s.on_close(ws.s, c, ws.closure)
		})
	}

	if s.on_open != nil {
		s.on_open(s, c)
	}

	scan(s, c, ws, size_of(_Frame_Header), on_frame_header)

	scan :: proc(s: ^Server, c: ^http.Connection, ws: ^Connection, n: int, cb: http.Scan_Cb) {
		if ws.arena == nil {
			ws.arena = http.bootstrap_arena(c)
		}
		http._scan_bytes(&c.scanner, n, s.idle_timeout, ws.arena, cb)
	}

	on_frame_header :: proc(c: ^http.Connection, data: []byte) {
		assert(len(data) == size_of(_Frame_Header))
		header := intrinsics.unaligned_load((^_Frame_Header)(raw_data(data)))

		if header.rsv1 || header.rsv2 || header.rsv3 {
			immediately_close(c, .Protocol_Error, "reserved bits set")
			return
		}

		switch header.opcode {
		case .Text, .Binary, .Continuation:
		case .Ping, .Pong, .Close:
			if !header.fin {
				immediately_close(c, .Protocol_Error, "fragmented control frame")
				return
			}
			if header.hpayload_len > 125 {
				immediately_close(c, .Protocol_Error, "invalid control frame length")
				return
			}
		case:
			immediately_close(c, .Protocol_Error, "invalid opcode")
			return
		}

		ws := http.context_get(&c.ctx, Connection)
		append(&ws.frames, _Frame{header = header})
		frame := &ws.frames[len(ws.frames)-1]

		switch header.hpayload_len {
		case _LEN_2_BYTES:
			scan(ws.s, c, ws, size_of(u16be), on_payload_len)
		case _LEN_8_BYTES:
			scan(ws.s, c, ws, size_of(u64be), on_payload_len)
		case:
			assert(header.hpayload_len <= 125)
			frame.payload_len = u64(header.hpayload_len)
			handle_payload_len(ws, c, frame)
		}
	}

	on_payload_len :: proc(c: ^http.Connection, data: []byte) {
		ws    := http.context_get(&c.ctx, Connection)
		frame := &ws.frames[len(ws.frames)-1]

		switch frame.header.hpayload_len {
		case _LEN_2_BYTES:
			assert(len(data) == size_of(u16be))
			frame.payload_len = u64(endian.unchecked_get_u16be(data))
		case _LEN_8_BYTES:
			assert(len(data) == size_of(u64be))
			frame.payload_len = u64(endian.unchecked_get_u64be(data))
		case: unreachable()
		}

		handle_payload_len(ws, c, frame)
	}

	handle_payload_len :: proc(ws: ^Connection, c: ^http.Connection, frame: ^_Frame) {
		_, _, size := _find_fragmented_head(ws)

		max_size := ws.s.max_message_size - size
		if max_size <= 0       { max_size = max(int) }
		if frame.header.masked { max_size = min(max_size, max(int)-size_of(_Mask)) }

		if frame.payload_len > u64(max_size) {
			immediately_close(c, .Too_Big, "message size too big")
			return
		}

		scan_size := int(frame.payload_len)
		if frame.header.masked {
			scan_size += size_of(_Mask)
		}

		scan(ws.s, c, ws, scan_size, on_payload)
	}

	on_payload :: proc(c: ^http.Connection, buf: []byte) {
		ws    := http.context_get(&c.ctx, Connection)
		frame := &ws.frames[len(ws.frames)-1]

		if frame.header.masked {
			_unmask(buf)
			frame.payload_data = buf[4:]
		} else {
			frame.payload_data = buf
		}

		handle_frame(ws, c, frame)
	}

	handle_frame :: proc(ws: ^Connection, c: ^http.Connection, frame: ^_Frame) {
		s := ws.s

		head, head_idx, size := _find_fragmented_head(ws)
		size += len(frame.payload_data)

		log.debugf("websocket[t=%v][c=%v]: opcode=%v, fin=%v", http.td.id, c.socket, frame.header.opcode, frame.header.fin)

		switch frame.header.opcode {
		case .Binary, .Text:
			if head != nil {
				immediately_close(c, .Protocol_Error, "non-continuation frame while expecting a continuation")
				return
			}

			if !frame.header.fin {
				handle_next_frame(c, ws)
				return
			}

			if frame.header.opcode == .Text && !ws.s.no_utf8_validation && !utf8.valid_string(string(frame.payload_data)) {
				send_close(c, .Inconsistent_Data, "Invalid UTF-8 text")
				pop(&ws.frames)
				handle_next_frame(c, ws)
				return
			}

			assert(s.on_message != nil, "no message handler set")
			message := Message{
				type  = Message_Type(frame.header.opcode),
				data  = frame.payload_data,
				arena = ws.arena,
			}
			s.on_message(s, c, message)
			ws.arena = nil

			pop(&ws.frames)

			handle_next_frame(c, ws)
			return

		case .Continuation:
			if head == nil {
				immediately_close(c, .Protocol_Error, "Continuation frame while no message is in progress")
				return
			}

			if !frame.header.fin {
				handle_next_frame(c, ws)
				return
			}

			message, err := make([]byte, size, http.arena_allocator(ws.arena))
			if err != nil {
				send_close(c, .Too_Big, "out of memory")
				resize(&ws.frames, 0)
				handle_next_frame(c, ws)
				return
			}

			n := 0
			for frame in ws.frames[head_idx:] {
				#partial switch frame.header.opcode {
				case .Continuation, .Text, .Binary:
					n += copy(message[n:], frame.payload_data)
				}
			}
			assert(n == size)

			if head.header.opcode == .Text && !s.no_utf8_validation && !utf8.valid_string(string(message)) {
				send_close(c, .Inconsistent_Data, "Invalid UTF-8 text")
				resize(&ws.frames, 0)
				handle_next_frame(c, ws)
				return
			}

			assert(s.on_message != nil, "no message handler set")
			msg := Message{
				type  = Message_Type(head.header.opcode),
				data  = message,
				arena = ws.arena,
			}
			s.on_message(s, c, msg)
			ws.arena = nil

			resize(&ws.frames, 0)

			handle_next_frame(c, ws)
			return

		case .Ping:
			// TODO: free arena in callback.
			_send(c, .Pong, frame.payload_data)
			pop(&ws.frames)
			handle_next_frame(c, ws)
			return

		case .Pong:
			// TODO: free arena in callback.
			pop(&ws.frames)
			handle_next_frame(c, ws)
			return

		case .Close:
			status := Status.No_Status
			reason: string
			if frame.payload_len >= 2 {
				status = Status(endian.unchecked_get_u16be(frame.payload_data))
				reason = string(frame.payload_data[2:])

				if !is_valid_status(status) {
					immediately_close(c, .Protocol_Error, "invalid close status code")
					return
				}
			}

			if !s.no_utf8_validation && !utf8.valid_string(reason) {
				send_close(c, .Inconsistent_Data, "close frame with invalid UTF-8 reason")
				pop(&ws.frames)
				handle_next_frame(c, ws)
				return
			}

			if ws.closure == nil {
				ws.closure = Closure{
					type   = .Client,
					status = status,
					reason = reason,
					arena  = ws.arena,
				}
				ws.arena = nil
				_send(c, .Close, frame.payload_data)
			}

			pop(&ws.frames)
			http.set_header(&c.res, "Connection", "close")
			http.respond(&c.res)
			return
		case:
			unreachable()
		}
	}

	handle_next_frame :: proc(c: ^http.Connection, ws: ^Connection) {
		scan(ws.s, c, ws, size_of(_Frame_Header), on_frame_header)
	}
}

_send :: proc(c: ^http.Connection, opcode: _Opcode, data: []byte, fin := true) {
	_send_multi(c, opcode, {data}, fin)
}

_send_multi :: proc(c: ^http.Connection, opcode: _Opcode, data: [][]byte, fin := true) {
	Outgoing_Frame_Header :: struct #packed {
		header: _Frame_Header,
		len:    struct #raw_union {
			len_8_bytes: u64be,
			len_2_bytes: u16be,
		},
	}
	// TODO: "leak"; sends will keep increasing mem until connection closed
	f := new_clone(Outgoing_Frame_Header{
		header = {
			opcode = opcode,
			fin    = fin,
		},
	}, http.transaction_allocator(c))

	data_len := 0
	for buf in data { data_len += len(buf) }

	length := size_of(_Frame_Header)
	switch {
	case data_len > int(max(u16)):
		f.header.hpayload_len = _LEN_8_BYTES
		length += size_of(u64)
		f.len.len_8_bytes = u64be(data_len)
	case data_len > 125:
		f.header.hpayload_len = _LEN_2_BYTES
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

_find_fragmented_head :: proc(ws: ^Connection) -> (head: ^_Frame, head_idx: int, size: int) {
	if len(ws.frames) > 1 {
		#reverse for &frame, i in ws.frames[:len(ws.frames)-1] {
			#partial switch frame.header.opcode {
			case .Continuation:
				size += len(frame.payload_data)
			case .Text, .Binary:
				assert(!frame.header.fin)
				head = &frame
				head_idx = i
				size += len(frame.payload_data)
				return
			}
		}
	}

	return
}

_unmask :: proc(buf: []byte) #no_bounds_check {
	buf  := buf
	mask := (^[4]byte)(raw_data(buf))^
	buf   = buf[4:]

	SIZE :: 16

	mask_vec: #simd [SIZE]byte = {
		mask[0], mask[1], mask[2], mask[3],
		mask[0], mask[1], mask[2], mask[3],
		mask[0], mask[1], mask[2], mask[3],
		mask[0], mask[1], mask[2], mask[3],
	}

	for len(buf) > SIZE {
		chunk := intrinsics.unaligned_load((^#simd [SIZE]byte)(raw_data(buf)))
		chunk  = intrinsics.simd_bit_xor(chunk, mask_vec)
		intrinsics.mem_copy_non_overlapping(raw_data(buf), (^[SIZE]byte)(&chunk), SIZE)
		buf = buf[SIZE:]
	}

	for &b, i in buf {
		b ~= mask[i & 3]
	}
}
