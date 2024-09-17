//+build !js
package nbio

import "base:runtime"

import "core:os"

@(private="file")
read_entire_file_alloc :: proc(io: ^IO, fd: os.Handle, allocator: runtime.Allocator) -> (buf: []byte, err: os.Errno) {
	size: i64
	if size, err = _file_size(io, fd); err != os.ERROR_NONE {
		return
	}

	if size <= 0 {
		return
	}

	isize := int(size)
	if isize <= 0 {
		err = os.ERROR_BUFFER_OVERFLOW when ODIN_OS == .Windows else os.EFBIG
		return
	}

	mem: runtime.Allocator_Error
	buf, mem = make([]byte, isize, allocator)
	if mem != nil {
		err = os.ERROR_NOT_ENOUGH_MEMORY when ODIN_OS == .Windows else os.ENOMEM
	}

	return
}

read_entire_file :: proc(fd: os.Handle, p: $T, callback: $C/proc(p: T, buf: []byte, err: os.Errno), allocator := context.allocator) -> ^Completion
	where size_of(T) + size_of([]byte) <= MAX_USER_ARGUMENTS {

	io := io()

	buf, err := read_entire_file_alloc(io, fd, allocator)
	if err != os.ERROR_NONE {
		callback(p, nil, err)
		return nil
	}

	completion := _read(io, fd, 0, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)     (rawptr(ptr)))
		buf := unall((^[]byte)(rawptr(ptr + size_of(C))))
		p   := unall((^T)     (rawptr(ptr + size_of(C) + size_of([]byte))))
		cb(p, buf, err)
	}, all = true)

	ptr := uintptr(&completion.user_args)

	unals((^C)     (rawptr(ptr)),                                callback)
	unals((^[]byte)(rawptr(ptr + size_of(C))),                   buf)
	unals((^T)     (rawptr(ptr + size_of(C) + size_of([]byte))), p)

	completion.user_data = completion
	return completion
}

read_entire_file2 :: proc(fd: os.Handle, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, buf: []byte, err: os.Errno), allocator := context.allocator) -> ^Completion
	where size_of(T) + size_of(T2) + size_of([]byte) <= MAX_USER_ARGUMENTS {

	io := io()

	buf, err := read_entire_file_alloc(io, fd, allocator)
	if err != os.ERROR_NONE {
		callback(p, p2, nil, err)
		return nil
	}

	completion := _read(io, fd, 0, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)     (rawptr(ptr)))
		buf := unall((^[]byte)(rawptr(ptr + size_of(C))))
		p   := unall((^T)     (rawptr(ptr + size_of(C) + size_of([]byte))))
		p2  := unall((^T2)    (rawptr(ptr + size_of(C) + size_of([]byte) + size_of(T))))
		cb(p, p2, buf, err)
	}, all = true)

	ptr := uintptr(&completion.user_args)

	unals((^C)     (rawptr(ptr)),                                             callback)
	unals((^[]byte)(rawptr(ptr + size_of(C))),                                buf)
	unals((^T)     (rawptr(ptr + size_of(C) + size_of([]byte))),              p)
	unals((^T2)    (rawptr(ptr + size_of(C) + size_of([]byte) + size_of(T))), p2)

	completion.user_data = completion
	return completion
}

read_entire_file3 :: proc(fd: os.Handle, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, buf: []byte, err: os.Errno), allocator := context.allocator) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) + size_of([]byte) <= MAX_USER_ARGUMENTS {

	io := io()

	buf, err := read_entire_file_alloc(io, fd, allocator)
	if err != os.ERROR_NONE {
		callback(p, p2, p3, nil, err)
		return nil
	}

	completion := _read(io, fd, 0, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)     (rawptr(ptr)))
		buf := unall((^[]byte)(rawptr(ptr + size_of(C))))
		p   := unall((^T)     (rawptr(ptr + size_of(C) + size_of([]byte))))
		p2  := unall((^T2)    (rawptr(ptr + size_of(C) + size_of([]byte) + size_of(T))))
		p3  := unall((^T3)    (rawptr(ptr + size_of(C) + size_of([]byte) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, buf, err)
	}, all = true)

	ptr := uintptr(&completion.user_args)

	unals((^C)     (rawptr(ptr)),                                                           callback)
	unals((^[]byte)(rawptr(ptr + size_of(C))),                                              buf)
	unals((^T)     (rawptr(ptr + size_of(C) + size_of([]byte))),                            p)
	unals((^T2)    (rawptr(ptr + size_of(C) + size_of([]byte) + size_of(T))),               p2)
	unals((^T3)    (rawptr(ptr + size_of(C) + size_of([]byte) + size_of(T) + size_of(T2))), p3)

	completion.user_data = completion
	return completion
}

write_entire_file :: #force_inline proc(fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return write_at_all_poly(fd, 0, buf, p, callback)
}

write_entire_file2 :: #force_inline proc(fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return write_at_all_poly2(fd, 0, buf, p, p2, callback)
}

write_entire_file3 :: #force_inline proc(fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return write_at_all_poly3(fd, 0, buf, p, p2, p3, callback)
}
