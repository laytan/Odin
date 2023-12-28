//+private
package os

foreign import sys "system:System.framework"

MEM_PROT_READ  :: 1
MEM_PROT_WRITE :: 2
MEM_PROT_EXEC  :: 3

MEM_ADVICE_NORMAL     :: 1
MEM_ADVICE_RANDOM     :: 2
MEM_ADVICE_SEQUENTIAL :: 3
MEM_ADVICE_WILL_NEED  :: 4
MEM_ADVICE_DONT_NEED  :: 5
MEM_ADVICE_FREE       :: 6

_mmap :: proc(size: uint, prot: Mem_Protection, flags: Map_Flags, addr: rawptr, fd: Handle, offset: i64) -> ([^]byte, Errno) {
	MAP_FAILED :: max(uintptr)

	fd := fd
	if fd == INVALID_HANDLE {
		fd = -1
	}

	iflags: i32
	if .Shared    in flags { iflags |= MAP_SHARED  }
	if .Private   in flags { iflags |= MAP_PRIVATE }
	if .Fixed     in flags { iflags |= MAP_FIXED   }
	if .Anonymous in flags { iflags |= MAP_ANON    }

	ret := __mmap(addr, size, transmute(i32)prot, iflags, i32(fd), offset)
	if uintptr(ret) == MAP_FAILED {
		return nil, Errno(get_last_error())
	}

	return ret, ERROR_NONE
}

_munmap :: proc(addr: rawptr, size: uint, _: Map_Flags) -> Errno {
	ret := __munmap(addr, size)
	if ret == -1 {
		return Errno(get_last_error())
	}

	return ERROR_NONE
}

_madvise :: proc(addr: rawptr, size: uint, advice: MAdvice) -> Errno {
	ret := __madvise(addr, size, i32(advice))
	if ret == -1 {
		return Errno(get_last_error())
	}

	return ERROR_NONE
}

@(private="file")
MAP_SHARED  :: 0x0001
@(private="file")
MAP_PRIVATE :: 0x0002
@(private="file")
MAP_FIXED   :: 0x0010
// NOTE: Because this is big, it can't be put in a bit_set.
@(private="file")
MAP_ANON    :: 0x1000

foreign sys {
	@(private="file", link_name="mmap")
	__mmap :: proc(addr: rawptr, size: uint, prot: i32, flags: i32, fd: i32, offset: i64) -> [^]byte ---

	@(private="file", link_name="munmap")
	__munmap :: proc(addr: rawptr, size: uint) -> i32 ---
	
	@(private="file", link_name="madvise")
	__madvise :: proc(addr: rawptr, size: uint, advice: i32) -> i32 ---
}
