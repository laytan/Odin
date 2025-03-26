package http

import    "base:intrinsics"
import rb "core:container/rbtree"
import    "core:strings"
import    "core:simd"

Headers :: struct {
	_kv:      rb.Tree(string, string),
	readonly: bool,
}

headers_init :: proc(h: ^Headers, allocator := context.allocator) {
	rb.init_cmp(&h._kv, headers_cmp, allocator)
}

headers_cmp :: proc(a, b: string) -> rb.Ordering #no_bounds_check {
	if len(a) < len(b) {
		return .Less
	} else if len(a) > len(b) {
		return .Greater
	}

	if true {
		// TODO: test if this is actually faster in practice, keys aren't long in practice.

		// NOTE: vectorized version

		LANES :: 8

		check: #simd [LANES]byte: 'A' - 1
		mask:  #simd [LANES]byte: 0x20

		i: int
		for ; i + LANES < len(a); i += LANES {
			a_chars := intrinsics.unaligned_load((^#simd [LANES]byte)(raw_data(a)[i:]))
			b_chars := intrinsics.unaligned_load((^#simd [LANES]byte)(raw_data(b)[i:]))

			a_lower := simd.bit_or(
				a_chars,
				simd.bit_and(
					simd.lanes_gt(
						a_chars,
						check,
					),
					mask,
				),
			)
			b_lower := simd.bit_or(
				b_chars,
				simd.bit_and(
					simd.lanes_gt(
						b_chars,
						check,
					),
					mask,
				),
			)

			ne_set := simd.extract_msbs(simd.lanes_ne(a_lower, b_lower))
			ne     := transmute(intrinsics.type_bit_set_underlying_type(type_of(ne_set)))ne_set
			if ne == 0 {
				continue
			}

			off := intrinsics.count_trailing_zeros(ne)
			return a[i + int(off)] > b[i + int(off)] ? .Greater : .Less
		}

		for ; i < len(a); i += 1 {
			ac := a[i]
			if ac >= 'A' && ac <= 'Z' {
				ac |= 0x20
			}

			bc := b[i]
			if bc >= 'A' && bc <= 'Z' {
				bc |= 0x20
			}

			if ac < bc {
				return .Less
			} else if ac > bc {
				return .Greater
			}
		}
	} else {
		// NOTE: scalar version

		for i in 0 ..< len(a) {
			ac := a[i]
			if ac >= 'A' && ac <= 'Z' {
				ac |= 0x20
			}

			bc := b[i]
			if bc >= 'A' && bc <= 'Z' {
				bc |= 0x20
			}

			if ac < bc {
				return .Less
			} else if ac > bc {
				return .Greater
			}
		}
	}

	return .Equal
}

// NOTE: only call this if the allocator is not temporary and you have individual free, this
// iterates the entire tree and is expensive.
headers_destroy :: proc(h: ^Headers) {
	rb.destroy(&h._kv, false)
}

Headers_Iterator :: rb.Iterator(string, string)

headers_iterator :: proc(h: ^Headers) -> Headers_Iterator {
	return rb.iterator(&h._kv, .Forward)
}

headers_next :: proc(iter: ^Headers_Iterator) -> (key: string, val: string, ok: bool) {
	n: ^rb.Node(string, string)
	n, ok = rb.iterator_next(iter)
	if n != nil {
		key = n.key
		val = n.value
	}
	return
}

headers_count :: #force_inline proc(h: Headers) -> int {
	return rb.len(h._kv)
}

headers_set :: proc(h: ^Headers, k: string, v: string, loc := #caller_location) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the server request or client response?", loc)
	n, ok, _ := rb.find_or_insert(&h._kv, k, v)
	assert(ok)
	assert(n.value == v)
}

headers_get :: proc(h: Headers, k: string) -> (string, bool) #optional_ok {
	return rb.find_value(h._kv, k)
}

headers_has :: proc(h: Headers, k: string) -> bool {
	n := rb.find(h._kv, k)
	return n != nil
}

headers_delete :: proc(h: ^Headers, k: string, loc := #caller_location) -> (deleted_key: string, deleted_value: string) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to delete a header on the server request or client response?", loc)

	n := rb.find(h._kv, k)
	if n == nil {
		return
	}

	deleted_key   = n.key
	deleted_value = n.value

	rb.remove_node(&h._kv, n, false)
	return
}

headers_entry :: proc(h: ^Headers, k: string, loc := #caller_location) -> (val: ^string) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to get a header on the server request or client response?", loc)

	n := rb.find(h._kv, k)
	if n == nil {
		return
	}

	return &n.value
}

/* Common Helpers */

headers_set_content_type :: proc {
	headers_set_content_type_mime,
	headers_set_content_type_string,
}

headers_set_content_type_string :: #force_inline proc(h: ^Headers, ct: string) {
	headers_set(h, "content-type", ct)
}

headers_set_content_type_mime :: #force_inline proc(h: ^Headers, ct: Mime_Type) {
	headers_set(h, "content-type", mime_to_content_type(ct))
}

headers_set_close :: #force_inline proc(h: ^Headers) {
	headers_set(h, "connection", "close")
}

// Validates the headers of a request, from the pov of the server.
headers_sanitize_for_server :: proc(headers: ^Headers) -> bool {
	// RFC 7230 5.4: A server MUST respond with a 400 (Bad Request) status code to any
	// HTTP/1.1 request message that lacks a Host header field.
	if !headers_has(headers^, "host") {
		return false
	}

	return headers_sanitize(headers)
}

// Validates the headers, use `headers_validate_for_server` if these are request headers
// that should be validated from the server side.
headers_sanitize :: proc(headers: ^Headers) -> bool {
	// RFC 7230 3.3.3: If a Transfer-Encoding header field
	// is present in a request and the chunked transfer coding is not
	// the final encoding, the message body length cannot be determined
	// reliably; the server MUST respond with the 400 (Bad Request)
	// status code and then close the connection.
	if enc_header, ok := headers_get(headers^, "transfer-encoding"); ok {
		strings.has_suffix(enc_header, "chunked") or_return

		// RFC 7230 3.3.3: If a message is received with both a Transfer-Encoding and a
		// Content-Length header field, the Transfer-Encoding overrides the
		// Content-Length.  Such a message might indicate an attempt to
		// perform request smuggling (Section 9.5) or response splitting
		// (Section 9.4) and ought to be handled as an error.
		headers_delete(headers, "content-length")
	}

	return true
}

// TODO: escaping?, streams (slow?)?
headers_write :: proc(sb: ^strings.Builder, headers: ^Headers) {
	iter := headers_iterator(headers)
	for header, value in headers_next(&iter) {
		strings.write_string(sb, header)
		strings.write_string(sb, ": ")
		strings.write_string(sb, value)
		strings.write_string(sb, "\r\n")
	}
}

// TODO: allocator
headers_to_string :: proc(headers: ^Headers) -> string {
	sb: strings.Builder
	headers_write(&sb, headers)
	return strings.to_string(sb)
}
