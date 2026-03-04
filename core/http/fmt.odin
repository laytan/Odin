package http

import "core:fmt"
import "core:io"

// Can be used with `fmt.register_user_formatter(http.Headers, http.headers_formatter)`.
headers_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	if verb != 'v' {
		return false
	}

	headers_write(fi.writer, (^Headers)(arg.data))
	return true

	headers_write :: proc(w: io.Writer, headers: ^Headers) -> io.Error {
		i: int
		for header, value in headers_iter(headers, &i) {
			io.write_string(w, header) or_return
			io.write_string(w, ": ")   or_return
			io.write_string(w, value)  or_return
			io.write_string(w, "\r\n") or_return
		}
		return nil
	}
}

