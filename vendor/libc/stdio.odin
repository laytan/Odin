package odin_libc

import "base:runtime"

import "core:c"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"

import stb "vendor:stb/sprintf"

FILE :: uintptr

@(require, linkage="strong", link_name="fopen")
fopen :: proc "c" (path: cstring, mode: cstring) -> FILE {
	context = g_ctx
	unimplemented("odin_libc.fopen")
}

@(require, linkage="strong", link_name="fseek")
fseek :: proc "c" (file: FILE, offset: c.long, whence: i32) -> i32 {
	context = g_ctx
	handle := os.Handle(file-1)
	_, err := os.seek(handle, i64(offset), int(whence))
	if err != nil {
		return -1
	}
	return 0
}

@(require, linkage="strong", link_name="ftell")
ftell :: proc "c" (file: FILE) -> c.long {
	context = g_ctx
	handle := os.Handle(file-1)
	off, err := os.seek(handle, 0, os.SEEK_CUR)
	if err != nil {
		return -1
	}
	return c.long(off)
}

@(require, linkage="strong", link_name="fclose")
fclose :: proc "c" (file: FILE) -> i32 {
	context = g_ctx
	handle := os.Handle(file-1)
	if os.close(handle) != nil {
		return -1
	}
	return 0
}

@(require, linkage="strong", link_name="fread")
fread :: proc "c" (buffer: [^]byte, size: uint, count: uint, file: FILE) -> uint {
	context = g_ctx
	handle := os.Handle(file-1)
	n, _   := os.read(handle, buffer[:min(size, count)])
	return uint(max(0, n))
}

@(require, linkage="strong", link_name="fwrite")
fwrite :: proc "c" (buffer: [^]byte, size: uint, count: uint, file: FILE) -> uint {
	context = g_ctx
	handle := os.Handle(file-1)
	n, _   := os.write(handle, buffer[:min(size, count)])
	return uint(max(0, n))
}

@(require, linkage="strong", link_name="vsnprintf")
vsnprintf :: proc "c" (buf: [^]byte, count: uint, fmt: cstring, args: ^c.va_list) -> i32 {
	i32_count := i32(count)
	assert_contextless(i32_count >= 0)
	return stb.vsnprintf(buf, i32_count, fmt, args)
}

@(require, linkage="strong", link_name="vfprintf")
vfprintf :: proc "c" (file: FILE, fmt: cstring, args: ^c.va_list) -> i32 {
	context = g_ctx

	handle := os.Handle(file-1)

	MAX_STACK :: 4096

	buf: []byte
	stack_buf: [MAX_STACK]byte = ---
	{
		n := stb.vsnprintf(&stack_buf[0], MAX_STACK, fmt, args)
		if n <= 0 {
			return n
		}

		if n >= MAX_STACK {
			buf = make([]byte, n)
			n2 := stb.vsnprintf(raw_data(buf), i32(len(buf)), fmt, args)
			assert(n == n2)
		} else {
			buf = stack_buf[:n]
		}
	}
	defer if len(buf) > MAX_STACK {
		delete(buf)
	}

	_, err := io.write_full(os.stream_from_handle(handle), buf)
	if err != nil {
		return -1
	}

	return i32(len(buf))
}

@(require, linkage="strong", link_name="__sscanf")
sscanf :: proc (_str, format: [^]byte, ptrs: [^]rawptr) -> (result: i32) {

	ptrs := ptrs

	str := string(cstring(_str))
	(^runtime.Raw_String)(&str).len += 1 // make the null byte part of the string for easier bounds.
	start_str := str

	// TODO: custom int parsing for C conventions and using the thousands quote thing.

	// TODO: input error result and EOF result.

	for i := 0; format[i] != 0; i += 1 {
		ch := format[i]

		// TODO: %n$

		// TODO: %l(c,s,[) modifier being wchar_t strings

		switch ch {
		case '%':

			suppression: bool // match, but discard it
			// TODO: use thousands
			thousands:   bool // decimal, may include thousand separators
			allocate:    bool // we will allocate the strings
			// TODO: use max_width in non-string specifiers too
			max_width:   int  // max field with, excluding discarded ws or the null byte for strings

			Type_Mod :: enum { none, h, hh, j, l, ll, L, q, t, z }
			type_mod: Type_Mod

			i += 1
			ch = format[i]

			switch ch {
			case  '*':
				suppression = true

				i += 1
				ch = format[i]

				if ch == '\'' {
					thousands = true

					i += 1
					ch = format[i]
				}

			case '\'':
				thousands = true

				i += 1
				ch = format[i]

				if ch == '*' {
					suppression = true

					i += 1
					ch = format[i]
				}
			}

			if ch == 'm' {
				allocate = true

				i += 1
				ch = format[i]
			}

			max_width_loop: for {
				switch ch {
				case 0:         return
				case:           break max_width_loop
				case '0'..='9':
					max_width *= 10
					max_width += int(ch - '0')

					i += 1
					ch = format[i]
				}
			}

			switch ch {
			case   0: return
			case 'h':
				type_mod = .h

				if format[i+1] == 'h' {
					type_mod = .hh

					i += 1
					ch = format[i]
				}
			case 'j':
				type_mod = .j
			case 'l':
				type_mod = .l

				if format[i+1] == 'l' {
					type_mod = .ll

					i += 1
					ch = format[i]
				}
			case 'L':
				type_mod = .L
			case 'q':
				type_mod = .q
			case 't':
				type_mod = .t
			case 'z':
				type_mod = .z
			}

			if type_mod != .none {
				i += 1
				ch = format[i]
			}

			switch str[0] {
			case 'c', 'C', '[', 'n':
			case:
				ws_loop: for {
					switch str[0] {
					case: break ws_loop
					case ' ', '\f', '\n', '\r', '\t', '\v':
						str = str[1:]
					}
				}
			}

			assign_int :: proc(suppression: bool, result: ^i32, ptrs: ^[^]rawptr, val: i64, mod: Type_Mod) {
				if suppression { return }

				result^ += 1

				ptr := ptrs[0]
				ptrs^ = ptrs[1:]

				#assert(size_of(val) >= size_of(c.intmax_t))

				#partial switch mod {
				case .h:     (^c.short)    (ptr)^ = (c.short)    (val)
				case .hh:    (^c.schar)    (ptr)^ = (c.schar)    (val)
				case .j:     (^c.intmax_t) (ptr)^ = (c.intmax_t) (val)
				case .l:     (^c.long)     (ptr)^ = (c.long)     (val)
				case .ll:    (^c.longlong) (ptr)^ = (c.longlong) (val)
				case .L, .q: (^c.longlong) (ptr)^ = (c.longlong) (val)
				case .t:     (^c.ptrdiff_t)(ptr)^ = (c.ptrdiff_t)(val)
				case .z:     (^c.ssize_t)  (ptr)^ = (c.ssize_t)  (val)
				case:        (^c.int)      (ptr)^ = (c.int)      (val)
				}
			}

			assign_uint :: proc(suppression: bool, result: ^i32, ptrs: ^[^]rawptr, val: u64, mod: Type_Mod) {
				if suppression { return }

				result^ += 1

				ptr := ptrs[0]
				ptrs^ = ptrs[1:]

				#assert(size_of(val) >= size_of(c.uintmax_t))

				#partial switch mod {
				case .h:     (^c.ushort)   (ptr)^ = (c.ushort)   (val)
				case .hh:    (^c.uchar)    (ptr)^ = (c.uchar)    (val)
				case .j:     (^c.uintmax_t)(ptr)^ = (c.uintmax_t)(val)
				case .l:     (^c.ulong)    (ptr)^ = (c.ulong)    (val)
				case .ll:    (^c.ulonglong)(ptr)^ = (c.ulonglong)(val)
				case .L, .q: (^c.ulonglong)(ptr)^ = (c.ulonglong)(val)
				case .t:     (^c.uintptr_t)(ptr)^ = (c.uintptr_t)(val)
				case .z:     (^c.size_t)   (ptr)^ = (c.size_t)   (val)
				case:        (^c.uint)     (ptr)^ = (c.uint)     (val)
				}
			}

			switch ch {
			case   0: return
			case    : return // unknown specifier
			case '%':
				if str[0] != '%' { return }
				str = str[1:]

			case 'd':
				n: int
				val, _ := strconv.parse_i64_of_base(str, 10, &n)
				str = str[n:]

				assign_int(suppression, &result, &ptrs, val, type_mod)

			case 'i':
				n: int
				val, _ := strconv.parse_i64_maybe_prefixed(str, n=&n)
				str = str[n:]

				assign_int(suppression, &result, &ptrs, val, type_mod)

			case 'o':
				n: int
				val, _ := strconv.parse_u64_of_base(str, 8, &n)
				str = str[n:]

				assign_uint(suppression, &result, &ptrs, val, type_mod)

			case 'u':
				n: int
				val, _ := strconv.parse_u64_of_base(str, 10, &n)
				str = str[n:]

				assign_uint(suppression, &result, &ptrs, val, type_mod)

			case 'x', 'X':
				str = strings.trim_prefix(str, "0x")
				str = strings.trim_prefix(str, "0X")
				
				n: int
				val, _ := strconv.parse_u64_of_base(str, 16, &n)
				str = str[n:]

				assign_uint(suppression, &result, &ptrs, val, type_mod)

			case 'p':
				str = strings.trim_prefix(str, "0x")
				str = strings.trim_prefix(str, "0X")

				n: int
				val, _ := strconv.parse_u64_of_base(str, 16, &n)
				str = str[n:]

				assign_uint(suppression, &result, &ptrs, val, type_mod)

			case 'n':
				assign_int(suppression, &{}, &ptrs, i64(len(start_str) - len(str)), type_mod)

			case 'f', 'e', 'g', 'E', 'a', 'A', 'F', 'G':
				n: int
				val, _ := strconv.parse_f64(str, &n)
				str = str[n:]

				if !suppression {
					ptr := ptrs[0]
					ptrs = ptrs[1:]
					result += 1

					#partial switch type_mod {
					case .l:
						(^c.double)(ptr)^ = c.double(val)
					case .L, .q:
						(^c.double)(ptr)^ = c.double(val) // longdouble
					case: 
						(^c.float)(ptr)^  = c.float(val)
					}
				}

			case 's':
				n: int
				str_loop: for sch in transmute([]byte)str {
					switch sch {
					case 0, ' ', '\f', '\n', '\r', '\t', '\v': break str_loop
					case:
						n += 1
						if max_width > 0 && n >= max_width {
							break str_loop
						}
					}
				}

				val := str[:n]
				str  = str[n:]

				if !suppression {
					if allocate {
						cloned, err := strings.clone_to_cstring(val)
						if err != nil { return }
						(^cstring)(ptrs[0])^ = cloned
						ptrs = ptrs[1:]
					} else {
						out := ([^]byte)(ptrs[0])[:len(val)+1]
						copy(out, val)
						out[len(val)] = 0
						ptrs = ptrs[1:]
					}
					result += 1
				}

			case 'c':
				max_width = max(max_width, 1)
				if len(str) < max_width {
					return
				}

				val := str[:max_width]
				str  = str[max_width:]

				if !suppression {
					if allocate {
						cloned, err := strings.clone_to_cstring(val)
						if err != nil { return }
						(^cstring)(ptrs[0])^ = cloned
						ptrs = ptrs[1:]
					} else {
						out := ([^]byte)(ptrs[0])[:len(val)]
						copy(out, val)
						ptrs = ptrs[1:]
					}
					result += 1
				}

			case 'S':
				unimplemented("sscanf wchar s")
			case 'C':
				unimplemented("sscanf wchar c")
			case '[':
				unimplemented("sscanf set")

				// is first char a ^

				// is first char (after possible ^) a ]
			}

		case ' ', '\f', '\n', '\r', '\t', '\v':
			ws_loop2: for {
				switch str[0] {
				case: break ws_loop2
				case ' ', '\f', '\n', '\r', '\t', '\v':
					str = str[1:]
				}
			}
		case:
			if str[0] != ch {
				return
			}
			str = str[1:]
		}
	}

	return
}
