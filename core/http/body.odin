#+build !js
package http

import "core:bufio"
import "core:io"
import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"

Body_Callback :: #type proc(user_data: rawptr, body: []byte, err: Body_Error)

Body_Error :: enum {
	None,
	Partial,
	Already_Consumed,
	Invalid_Content_Length,
	Exceeds_Max_Size,
	EOF,
	Timeout,
	Corrupted_State,
	Invalid_Trailing_Header,
	Unknown,
}

Has_Body :: struct {
	headers: Headers,
	_body: struct {
		err:      Body_Error,
		consumed: bool,
		cbs: struct {
			using _: _Cb,
			others: [dynamic]_Cb,
		},
	},
	_scanner: ^Scanner,
}

@(private="file")
_Cb :: struct {
	cb:        Body_Callback,
	user_data: rawptr,
}

/*
Retrieves the request's body.

If the request has the chunked Transfer-Encoding header set, the chunks are all read and returned.
Otherwise, the Content-Length header is used to determine what to read and return it.

`max_length` can be used to set a maximum amount of bytes we try to read, once it goes over this,
an error is returned.

Do not call this more than once.

**Tip** If an error is returned, easily respond with an appropriate error code like this, `http.respond(res, http.body_error_status(err))`.
*/
body :: proc(sub: ^Has_Body, max_length: int, user_data: rawptr, cb: Body_Callback) {
	if sub._body.consumed {
		cb(user_data, nil, sub._body.err != nil ? sub._body.err : .Already_Consumed)
		return
	}

	if sub._body.cbs.cb == nil {
		sub._body.cbs.cb        = cb
		sub._body.cbs.user_data = user_data

		enc_header, ok := headers_get(sub.headers, "transfer-encoding")
		if ok && strings.has_suffix(enc_header, "chunked") {
			_body_chunked(sub, max_length)
		} else {
			_body_length(sub, max_length)
		}
	} else {
		context.allocator = context.temp_allocator // TODO: FUCK
		append(&sub._body.cbs.others, _Cb{
			cb        = cb,
			user_data = user_data,
		})
	}
}

// TODO: should we have this?
// body_sync :: proc(sub: ^Has_Body, max_length: int) -> (Body, Body_Error) {
// 	Ret :: struct {
// 		done: bool,
// 		body: Body,
// 		err:  Body_Error,
// 	}
// 	r: Ret
//
// 	body(sub, max_length, &r, proc(r: rawptr, body: Body, err: Body_Error) {
// 		r := (^Ret)(r)
// 		r.done = true
// 		r.body = body
// 		r.err  = err
// 	})
//
// 	if err := nbio.run_until(&r.done); err != nil {
// 		if r.err == nil {
// 			r.err = .Unknown
// 		}
// 		log.errorf("nbio: %v", nbio.error_string(err))
// 	}
//
// 	return r.body, r.err
// }

/*
Parses a URL encoded body, aka bodies with the 'Content-Type: application/x-www-form-urlencoded'.

Key&value pairs are percent decoded and put in a map.
*/
body_url_encoded :: proc(plain: string, allocator := context.temp_allocator) -> (res: map[string]string, ok: bool) {

	insert :: proc(m: ^map[string]string, plain: string, keys: int, vals: int, end: int, allocator := context.temp_allocator) -> bool {
		has_value := vals != -1
		key_end   := vals - 1 if has_value else end
		key       := plain[keys:key_end]
		val       := plain[vals:end] if has_value else ""

		// PERF: this could be a hot spot and I don't like that we allocate the decoded key and value here.
		keye := (net.percent_decode(key, allocator) or_return) if strings.index_byte(key, '%') > -1 else key
		vale := (net.percent_decode(val, allocator) or_return) if has_value && strings.index_byte(val, '%') > -1 else val

		m[keye] = vale
		return true
	}

	count := 1
	for b in plain {
		if b == '&' { count += 1 }
	}

	queries := make(map[string]string, count, allocator)

	keys := 0
	vals := -1
	for b, i in plain {
		switch b {
		case '=':
			vals = i + 1
		case '&':
			insert(&queries, plain, keys, vals, i) or_return
			keys = i + 1
			vals = -1
		}
	}

	insert(&queries, plain, keys, vals, len(plain)) or_return

	return queries, true
}

// Returns an appropriate status code for the given body error.
body_error_status :: proc(e: Body_Error) -> Status {
	switch e {
	case .None:
		return .OK
	case .Partial, .Already_Consumed: // This is not actually a hard error and shouldn't get here.
		return .Internal_Server_Error
	case .Invalid_Content_Length, .EOF, .Timeout, .Invalid_Trailing_Header:
		return .Bad_Request
	case .Exceeds_Max_Size:
		return .Payload_Too_Large
	case .Corrupted_State, .Unknown:
		return .Internal_Server_Error
	case:
		return .Internal_Server_Error
	}
}

// Returns an appropriate status code for the given body error.
_bufio_error_to_body_error :: proc(e: bufio.Scanner_Error, loc := #caller_location) -> Body_Error {
	switch t in e {
	case bufio.Scanner_Extra_Error:
		switch t {
		case .None:
			return .None
		case .Too_Long:
			return .Exceeds_Max_Size
		case .Too_Short, .Bad_Read_Count, .Negative_Advance, .Advanced_Too_Far:
			log.error(e, location=loc)
			return .Corrupted_State
		case:
			return .Unknown
		}
	case io.Error:
		switch t {
		case .None:
			return .None
		case .EOF, .Unexpected_EOF:
			return .EOF
		case .Unknown:
			return .Unknown
		case .No_Progress:
			return .Timeout
		case .Empty, .Short_Write, .Buffer_Full, .Short_Buffer,
		     .Invalid_Write, .Negative_Read, .Invalid_Whence, .Invalid_Offset,
			 .Invalid_Unread, .Negative_Write, .Negative_Count:
			log.error(e, location=loc)
			return .Corrupted_State
		case:
			return .Unknown
		}
	case:
		return .Unknown
	}
}

// "Decodes" a request body based on the content length header.
// Meant for internal usage, you should use `http.request_body`.
_body_length :: proc(sub: ^Has_Body, max_length: int = -1) {
	len, ok := headers_get(sub.headers, "content-length")
	if !ok {
		_body_do_cbs(sub, nil, nil)
		return
	}

	ilen, lenok := strconv.parse_int(len, 10)
	if !lenok {
		_body_do_cbs(sub, nil, .Invalid_Content_Length)
		return
	}

	if max_length > -1 && ilen > max_length {
		_body_do_cbs(sub, nil, .Exceeds_Max_Size)
		return
	}

	if ilen == 0 {
		_body_do_cbs(sub, nil, nil)
		return
	}

	sub._scanner.max_token_size = ilen

	sub._scanner.split = scan_whatever
	sub._scanner.split_data = sub

	scanner_scan(sub._scanner, sub, on_body_content)
	on_body_content :: proc(sub: ^Has_Body, token: string, err: bufio.Scanner_Error) {
		if err != nil {
			_body_do_cbs(sub, token, _bufio_error_to_body_error(err))
			return
		}

		sub._scanner.max_token_size -= len(token)
		assert(sub._scanner.max_token_size >= 0)

		if sub._scanner.max_token_size == 0 {
			_body_do_cbs(sub, token, nil)
			return
		}

		_body_do_cbs(sub, token, .Partial)
		scanner_scan(sub._scanner, sub, on_body_content)
	}
}

scan_whatever :: proc(sub: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	sub := (^Has_Body)(sub)

	n := sub._scanner.max_token_size

	if at_eof && len(data) < n {
		return
	}

	read := min(len(data), n)
	return read, data[:read], nil, false
}

/*
"Decodes" a chunked transfer encoded request body.
Meant for internal usage, you should use `http.request_body`.

PERF: this could be made non-allocating by writing over the part of the body that contains the
metadata with the rest of the body, and then returning a slice of that, but it is some effort and
I don't think this functionality of HTTP is used that much anyway.

RFC 7230 4.1.3 pseudo-code:

length := 0
read chunk-size, chunk-ext (if any), and CRLF
while (chunk-size > 0) {
   read chunk-data and CRLF
   append chunk-data to decoded-body
   length := length + chunk-size
   read chunk-size, chunk-ext (if any), and CRLF
}
read trailer field
while (trailer field is not empty) {
   if (trailer field is allowed to be sent in a trailer) {
   	append trailer field to existing header fields
   }
   read trailer-field
}
Content-Length := length
Remove "chunked" from Transfer-Encoding
Remove Trailer from existing header fields
*/
_body_chunked :: proc(sub: ^Has_Body, max_length: int = -1) {

	on_scan :: proc(s: ^Chunked_State, size_line: string, err: bufio.Scanner_Error) {
		size_line := size_line

		if err != nil {
			_body_do_cbs(s.sub, nil, _bufio_error_to_body_error(err))
			return
		}

		// If there is a semicolon, discard everything after it,
		// that would be chunk extensions which we currently have no interest in.
		if semi := strings.index_byte(size_line, ';'); semi > -1 {
			size_line = size_line[:semi]
		}

		size, ok := strconv.parse_int(string(size_line), 16)
		if !ok {
			log.infof("Encountered an invalid chunk size when decoding a chunked body: %q", string(size_line))
			_body_do_cbs(s.sub, nil, .Invalid_Content_Length)
			return
		}

		// start scanning trailer headers.
		if size == 0 {
			scanner_scan(s.sub._scanner, s, on_scan_trailer)
			return
		}

		if s.max_length > -1 && size > s.max_length {
			_body_do_cbs(s.sub, nil, .Exceeds_Max_Size)
			return
		}
		s.max_length -= size

		s.sub._scanner.max_token_size = size

		s.sub._scanner.split      = scan_whatever
		s.sub._scanner.split_data = s.sub

		scanner_scan(s.sub._scanner, s, on_body_content)
		on_body_content :: proc(s: ^Chunked_State, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				_body_do_cbs(s.sub, token, _bufio_error_to_body_error(err))
				return
			}

			s.max_length -= len(token)
			s.sub._scanner.max_token_size -= s.max_length
			assert(s.sub._scanner.max_token_size >= 0)

			_body_do_cbs(s.sub, token, .Partial)

			if s.sub._scanner.max_token_size == 0 {
				on_scan_chunk(s)
			} else {
				scanner_scan(s.sub._scanner, s, on_body_content)
			}
		}
	}

	on_scan_chunk :: proc(s: ^Chunked_State) {
		s.sub._scanner.max_token_size = s.max_length
		s.sub._scanner.split          = scan_lines

		on_scan_empty_line :: proc(s: ^Chunked_State, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				_body_do_cbs(s.sub, nil, _bufio_error_to_body_error(err))
				return
			}
			// TODO: an actual error.
			assert(len(token) == 0)

			s.max_length -= len(token)
			s.sub._scanner.max_token_size = s.max_length

			scanner_scan(s.sub._scanner, s, on_scan)
		}

		scanner_scan(s.sub._scanner, s, on_scan_empty_line)
	}

	// TODO: this needs changing to accomedate the client.

	on_scan_trailer :: proc(s: ^Chunked_State, line: string, err: bufio.Scanner_Error) {
		// Headers are done, success.
		if err != nil || len(line) == 0 {
			headers_delete(&s.sub.headers, "trailer")

			s.sub.headers.readonly = false
			entry := headers_entry(&s.sub.headers, "transfer-encoding")
			entry^ = strings.trim_suffix(entry^, "chunked")
			s.sub.headers.readonly = true

			_body_do_cbs(s.sub, nil, nil)
			return
		}

		key, ok := header_parse(&s.sub.headers, string(line), context.temp_allocator)
		if !ok {
			log.infof("Invalid header when decoding chunked body: %q", string(line))
			_body_do_cbs(s.sub, nil, .Invalid_Trailing_Header)
			return
		}

		// A recipient MUST ignore (or consider as an error) any fields that are forbidden to be sent in a trailer.
		if !header_allowed_trailer(key) {
			log.infof("Invalid trailer header received, discarding it: %q", key)
			headers_delete(&s.sub.headers, key)
		}

		s.max_length -= len(line)
		s.sub._scanner.max_token_size -= s.max_length

		scanner_scan(s.sub._scanner, s, on_scan_trailer)
	}

	Chunked_State :: struct {
		sub:        ^Has_Body,
		max_length: int,
	}

	// TODO: lose the hidden temp ally.
	s := new(Chunked_State, context.temp_allocator)

	s.sub        = sub
	s.max_length = max_length

	s.sub._scanner.split = scan_lines
	scanner_scan(s.sub._scanner, s, on_scan)
}

@(private="file")
_body_do_cbs_bytes :: proc(sub: ^Has_Body, body: []byte, err: Body_Error) {
	sub._body.err = err
	sub._body.consumed = true

	sub._body.cbs.cb(sub._body.cbs.user_data, body, err)
	for other in sub._body.cbs.others {
		other.cb(other.user_data, body, err)
	}
}

@(private="file")
_body_do_cbs_string :: proc(sub: ^Has_Body, body: string, err: Body_Error) {
	_body_do_cbs(sub, transmute([]byte)body, err)
}

@(private="file")
_body_do_cbs :: proc {
	_body_do_cbs_string,
	_body_do_cbs_bytes,
}
