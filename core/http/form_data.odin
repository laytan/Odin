#+vet explicit-allocators
package http

import "core:encoding/hex"
import "core:io"
import "core:math/rand"
import "core:mem"
import "core:strings"

import os "core:os/os2"

Form_Data :: struct {
	fields:   [dynamic]Form_Data_Part,
	boundary: i64,
	progress: int,
	state: enum {
		Next,
		Content_Disposition,
		Content_Type,
		Content,
		Done,
	},
}

form_data_destroy :: proc(fd: ^Form_Data) {
	for field in fd.fields {
		delete(field.content_disposition, fd.fields.allocator)
	}
	delete(fd.fields)
}

form_data_add_to_request :: proc(fd: ^Form_Data, req: ^Outgoing_Request, allocator := context.allocator) -> mem.Allocator_Error {
	if req.method == .Get {
		req.method = .Post
	}
	req.body.content = form_data_reader(fd)

	if req.headers.spots == nil {
		req.headers = headers_make(allocator)
	}

	headers_set(&req.headers, "Content-Type", form_data_content_type(fd, allocator) or_return)

	return nil
}

form_data_remove_from_request :: proc(fd: ^Form_Data, req: ^Outgoing_Request, allocator := context.allocator) {
	_, val := headers_delete(req.headers, "Content-Type")
	delete(val, allocator)
}

Form_Data_Part :: struct {
	content_disposition: string,
	content_type:        string,
	content:             union {
		io.Reader,
		strings.Reader,
	},
}

form_data_append :: proc(fd: ^Form_Data, name, value: string, filename := "") -> mem.Allocator_Error {
	append_nothing(&fd.fields) or_return

	field := &fd.fields[len(fd.fields)-1]
	field.content_disposition = _form_data_make_content_disposition(name, filename, fd.fields.allocator) or_return

	reader: strings.Reader
	strings.reader_init(&reader, value)
	field.content = reader

	return nil
}

form_data_append_stream :: proc(fd: ^Form_Data, name, filename: string, stream: io.Reader) -> mem.Allocator_Error {
	assert(len(name) > 0)

	append_nothing(&fd.fields) or_return

	field := &fd.fields[len(fd.fields)-1]
	field.content_disposition = _form_data_make_content_disposition(name, filename, fd.fields.allocator) or_return
	field.content = stream

	return nil
}

form_data_append_reader :: form_data_append_stream

form_data_append_file :: proc(fd: ^Form_Data, name: string, file: ^os.File, filename := "") -> mem.Allocator_Error {
	filename := filename
	if filename == "" {
		_, filename = os.split_path(os.name(file))
	}

	return form_data_append_stream(fd, name, filename, os.to_reader(file))
}

/*
Initialize the form data with a custom boundary and/or allocator.

The structure is zero is initialized, so this is not a mandatory call.
*/
form_data_init :: proc(fd: ^Form_Data, boundary: i64 = 0, allocator := context.allocator) {
	fd.fields.allocator = allocator
	fd.boundary = boundary
}

/*
Returns the content type value for this form data.

The value needs to be used as the `"Content-Type"` header on the outgoing request.
*/
@(require_results)
form_data_content_type :: proc(fd: ^Form_Data, allocator := context.allocator) -> (ct: string, err: mem.Allocator_Error) {
	if fd.boundary == 0 {
		fd.boundary = rand.int63()
	}

	prefix := "multipart/form-data; boundary="
	buf := make([]byte, len(prefix) + size_of(fd.boundary)*2, allocator) or_return
	n := copy(buf, prefix)

	boundary_bytes := (transmute([size_of(i64)]byte)fd.boundary)
	hex.encode_into(buf[n:], boundary_bytes[:])

	return string(buf), nil
}

/*
Returns an `io.Reader` to be used as the body of an outgoing request.
*/
@(require_results)
form_data_reader :: proc(fd: ^Form_Data) -> io.Reader {
	return {
		data      = fd,
		procedure = _form_data_reader_proc,
	}
} 

_form_data_reader_proc :: proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	fd := (^Form_Data)(stream_data)
	assert(fd.boundary != 0, "form data has no boundary, did you forget to call and use `form_data_content_type`?")


	#partial switch mode {
	case .Query:
		return io.query_utility({ .Query, .Read, .Size })

	// NOTE: knowing the size helps the HTTP client optimize it's strategy. So this seemed worth it.
	case .Size:
		// --<boundary>\r\n
		boundary_len := i64(2 + size_of(i64)*2 + 2)

		for &field in fd.fields {
			n += boundary_len
			n += len("Content-Disposition: ")
			n += i64(len(field.content_disposition))
			n += len("\r\n")

			if field.content_type != "" {
				n += len("Content-Type: ")
				n += i64(len(field.content_type))
				n += len("\r\n")
			}

			n += len("\r\n")

			content := unwrap_content(&field)
			n += io.size(content) or_return
			n += len("\r\n")
		}

		n += boundary_len
		n += len("\r\n")
		return

	case .Read:
		for {
			switch fd.state {
			case .Next:
				if len(fd.fields) > fd.progress {
					defer if err == nil { fd.state = .Content_Disposition }
					return boundary(fd, p)
				} else {
					defer if err == nil { fd.state = .Done }
					return boundary(fd, p, end=true)
				}
			case .Content_Disposition:
				field := fd.fields[fd.progress]
				assert(field.content_disposition != "")

				defer if err == nil { fd.state = .Content_Type }
				return header(p, "Content-Disposition", field.content_disposition)

			case .Content_Type:
				field := fd.fields[fd.progress]

				defer if err == nil { fd.state = .Content }

				if field.content_type == "" {
					return nl(p)
				} else {
					return header(p, "Content-Type", field.content_type, add="\r\n")
				}

			case .Content:
				field := &fd.fields[fd.progress]

				content := unwrap_content(field)
				n, err = content.procedure(content.data, .Read, p, 0, nil)
				if err != .EOF {
					return
				}

				assert(n == 0)

				err = nil
				defer if err == nil {
					fd.progress += 1
					fd.state = .Next
				}

				return nl(p)

			case .Done:
				return 0, .EOF
			}
		}
	case:
		return 0, .Unsupported
	}

	@(require_results)
	boundary :: proc(fd: ^Form_Data, p: []byte, end := false) -> (_n: i64, err: io.Error) {
		needed := 2 + size_of(i64)*2 + 2
		if end {
			needed += 2
		}

		if needed > len(p) {
			return 0, .Short_Buffer
		}

		boundary_bytes := (transmute([size_of(i64)]byte)fd.boundary)

		n := copy(p, "--")
		n += len(hex.encode_into(p[n:], boundary_bytes[:]))
		if end {
			n += copy(p[n:], "--")
		}
		n += copy(p[n:], "\r\n")

		_n = i64(n)
		return
	}

	@(require_results)
	header :: proc(p: []byte, key, val: string, add: string = "") -> (_n: i64, err: io.Error) {
		needed := len(key) + len(": ") + len(val) + len(add) + len("\r\n")
		if needed > len(p) {
			return 0, .Short_Buffer
		}

		n := copy(p, key)
		n += copy(p[n:], ": ")
		n += copy(p[n:], val)
		n += copy(p[n:], add)
		n += copy(p[n:], "\r\n")

		_n = i64(n)
		return
	}

	@(require_results)
	nl :: proc(p: []byte) -> (_n: i64, err: io.Error) {
		needed := len("\r\n")
		if needed > len(p) {
			return 0, .Short_Buffer
		}

		n := copy(p, "\r\n")

		_n = i64(n)
		return
	}

	@(require_results)
	unwrap_content :: proc(field: ^Form_Data_Part) -> io.Stream {
		switch &backing in field.content {
		case io.Reader:      return backing
		case strings.Reader: return strings.reader_to_stream(&backing)
		case:                panic("Form_Data_Part without content?")
		}
	}
}

@(require_results)
_form_data_make_content_disposition :: proc(name, filename: string, allocator := context.allocator) -> (content_disposition: string, err: mem.Allocator_Error) {
	name := name
	assert(len(name) > 0)

	size := len(`form-data; name=""`)
	if filename != "" {
		size += len(`; filename=""`)
	}

	size += len(name)
	size += strings.count(name, `"`)
	size += strings.count(name, `\`)

	size += len(filename)
	size += strings.count(filename, `"`)
	size += strings.count(filename, `\`)

	buf := make([]byte, size, allocator) or_return

	n := copy(buf, `form-data; name="`)
	n += write_escaped_quotes(buf[n:], name)
	if filename != "" {
		n += copy(buf[n:], `"; filename="`)
		n += write_escaped_quotes(buf[n:], filename)
	}
	n += copy(buf[n:], `"`)

	assert(n == size)

	return string(buf), nil

	write_escaped_quotes :: proc(dst: []byte, str: string) -> (n: int) {
		str := str
		for part in strings.split_multi_after_iterator(&str, {`"`, `\`}) {
			switch part[len(part)-1] {
			case '"', '\\':
				n += copy(dst[n:], part[:len(part)-1])
				n += copy(dst[n:], `\`)
				n += copy(dst[n:], part[len(part)-1:])
			case:
				n += copy(dst[n:], part)
			}
		}
		return
	}
}
