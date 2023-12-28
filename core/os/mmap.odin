package os

import "core:intrinsics"

Mem_Protection :: bit_set[Mem_Protection_Bits; i32]

Mem_Protection_Bits :: enum {
	Read  = MEM_PROT_READ,
	Write = MEM_PROT_WRITE,
	Exec  = MEM_PROT_EXEC,
}

Map_Flags_Bits :: enum {
	Shared            = 0,
	Private           = 1,
	Fixed             = 4,
	Anonymous         = 5,
	Linux_Huge_Tables = 18, // NOTE: Ignored on non-Linux.
}

Map_Flags :: bit_set[Map_Flags_Bits; i32]

MAdvice :: enum {
	Normal     = MEM_ADVICE_NORMAL,
	Random     = MEM_ADVICE_RANDOM,
	Sequential = MEM_ADVICE_SEQUENTIAL,
	Will_Need  = MEM_ADVICE_WILL_NEED,
	Dont_Need  = MEM_ADVICE_DONT_NEED,
	Free       = MEM_ADVICE_FREE,
}

mmap :: proc {
	mmap_bytes,
	mmap_type,
}

mmap_bytes :: proc(
	size: uint,
	prot: Mem_Protection = {.Read},
	flags: Map_Flags = {},
	addr: rawptr = nil,
	fd: Handle = INVALID_HANDLE,
	offset: i64 = 0,
) -> ([]byte, Errno) {
	ptr, err := _mmap(size, prot, flags, addr, fd, offset)
	if err != ERROR_NONE {
		return nil, err
	}

	return ptr[:size], ERROR_NONE
}

mmap_type :: proc(
	$T: typeid,
	prot: Mem_Protection = {.Read},
	flags: Map_Flags = {},
	addr: rawptr = nil,
	fd: Handle = INVALID_HANDLE,
	offset: i64 = 0,
) -> (^T, Errno) {
	ptr, err := _mmap(size_of(T), prot, flags, addr, fd, offset)
	if err != ERROR_NONE {
		return nil, err
	}

	return (^T)(ptr), ERROR_NONE
}

munmap :: proc {
	munmap_type,
	munmap_bytes,
}

munmap_bytes :: proc(bytes: []byte, flags: Map_Flags = {}) -> Errno {
	return _munmap(raw_data(bytes), len(bytes), flags)
}

munmap_type :: proc(t: $T, flags: Map_Flags = {}) -> Errno where intrinsics.type_is_pointer(T) {
	return _munmap(t, size_of(T), flags)
}

// NOTE: This is a no-op on Windows.
madvise :: proc {
	madvise_type,
	madvise_bytes,
}

madvise_bytes :: proc(bytes: []byte, advice: MAdvice) -> Errno {
	return _madvise(raw_data(bytes), len(bytes), advice)
}

madvise_type :: proc(t: $T, advice: MAdvice) -> Errno where intrinsics.type_is_pointer(T) {
	return _madvise(t, size_of(T), advice)
}
