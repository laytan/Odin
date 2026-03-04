package websocket

import "base:intrinsics"

import "core:encoding/endian"
import "core:slice"
import "core:strings"
import "core:encoding/base64"
import "core:crypto/hash"
import "core:crypto/legacy/sha1"

import http "core:http2"

@(rodata)
GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

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

scan_frame :: proc(c: ^http.Connection) -> (frame: Frame, ok: bool) {
	header_bytes := http.scan_n(c, size_of(Frame_Header)) or_return
	frame.header, _ = slice.to_type(header_bytes, Frame_Header)

	switch frame.header.hpayload_len {
	case LEN_2_BYTES:
		len_bytes := http.scan_n(c, size_of(u16be)) or_return
		frame.payload_len = u64(endian.unchecked_get_u16be(len_bytes))
	case LEN_8_BYTES:
		len_bytes := http.scan_n(c, size_of(u64be)) or_return
		frame.payload_len = u64(endian.unchecked_get_u64be(len_bytes))
	case:
		assert(frame.header.hpayload_len <= 125)
		frame.payload_len = u64(frame.header.hpayload_len)
	}

	size := int(min(u64(max(int)) - size_of(Mask), frame.payload_len))
	if frame.header.masked {
		size += size_of(Mask)
	}

	buf := http.scan_n(c, size) or_return
	if frame.header.masked {
		unmask(buf)
		frame.payload_data = buf[4:]
	} else {
		frame.payload_data = buf
	}

	ok = true
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

scan_frame_or_recv :: proc(c: ^http.Connection, cb: http.Scan_Cb) -> (frame: Frame, ok: bool) {
	frame, ok = scan_frame(c)
	if !ok {
		http.scan_recv(c, http.get_timeout(c.last_recv_dur, &c.body_quota, c.last_recv_n), cb)
	}
	return
}
