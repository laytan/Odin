package websocket

import "base:intrinsics"

import "core:crypto/hash"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:slice"
import "core:strings"
import "core:time"

import http "core:http2"

@(rodata)
GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

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

Opcode :: enum u8 {
	Continuation,
	Text,
	Binary,
	Close = 8,
	Ping,
	Pong,
}

Frame_Header :: bit_field u16 {
	opcode:       Opcode | 4,
	rsv3:         bool   | 1,
	rsv2:         bool   | 1,
	rsv1:         bool   | 1,
	fin:          bool   | 1,
	hpayload_len: u8     | 7,
	masked:       bool   | 1,
}

Frame :: struct {
	header: Frame_Header,
	payload_len:  u64,
	payload_data: []byte,
}

Mask :: [4]byte

// Magic frame header length indicates length of payload is the following 2 bytes (as a u16be).
LEN_2_BYTES :: 126

// Magic frame header length indicates length of payload is the following 8 bytes (as a u64be).
LEN_8_BYTES :: 127

prepare_upgrade :: proc(req: ^http.Request, res: ^http.Response) -> bool {
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
		hash.update(&ctx, transmute([]byte)GUID)

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

upgrade :: proc(req: ^http.Request, res: ^http.Response) -> bool {
	ok := prepare_upgrade(req, res)
	if !ok {
		http.respond(res)
	} else {
		http.send_heading(res)
	}
	return ok
}

scan_frame_header :: proc(c: ^http.Connection) -> (frame: Frame, res: Scan_Result) {
	header_bytes, ok := http.scan_n(c, size_of(Frame_Header))
	if !ok { res = .Needs_Recv; return }
	frame.header, _ = slice.to_type(header_bytes, Frame_Header)

	switch frame.header.hpayload_len {
	case LEN_2_BYTES:
		len_bytes, len_ok := http.scan_n(c, size_of(u16be))
		if !len_ok { res = .Needs_Recv; return }
		frame.payload_len = u64(endian.unchecked_get_u16be(len_bytes))
	case LEN_8_BYTES:
		len_bytes, len_ok := http.scan_n(c, size_of(u64be))
		if !len_ok { res = .Needs_Recv; return }
		frame.payload_len = u64(endian.unchecked_get_u64be(len_bytes))
	case:
		assert(frame.header.hpayload_len <= 125)
		frame.payload_len = u64(frame.header.hpayload_len)
	}

	return
}

scan_frame :: proc(c: ^http.Connection, max_size: int) -> (frame: Frame, res: Scan_Result) {
	frame = scan_frame_header(c) or_return

	max_size := max_size
	if max_size < 0        { max_size = max(int) }
	if frame.header.masked { max_size = min(max_size, max(int)-size_of(Mask)) }

	if frame.payload_len > u64(max_size) { res = .Max_Size_Exceeded; return }

	size := int(frame.payload_len)
	if frame.header.masked {
		size += size_of(Mask)
	}

	buf, buf_ok := http.scan_n(c, size)
	if !buf_ok { res = .Needs_Recv; return }

	if frame.header.masked {
		unmask(buf)
		frame.payload_data = buf[4:]
	} else {
		frame.payload_data = buf
	}

	return

	unmask :: proc(buf: []byte) #no_bounds_check {
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
}

Scan_Result :: enum {
	Ok,
	Max_Size_Exceeded,
	Needs_Recv,
	Will_Callback,
}

scan_frame_or_recv :: proc(c: ^http.Connection, max_size: int, timeout: time.Duration, cb: http.Scan_Cb) -> (frame: Frame, res: Scan_Result) {
	frame, res = scan_frame(c, max_size)
	if res == .Needs_Recv {
		res = .Will_Callback
		c.body_quota = {}
		http.scan_recv(c, timeout <= 0 ? http.NO_TIMEOUT : timeout, cb)
	}
	return
}
