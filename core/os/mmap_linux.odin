//+private
package os

import "core:sys/linux"

MEM_PROT_READ  :: int(linux.Mem_Protection_Bits.READ)
MEM_PROT_WRITE :: int(linux.Mem_Protection_Bits.WRITE)
MEM_PROT_EXEC  :: int(linux.Mem_Protection_Bits.EXEC)

MEM_ADVICE_NORMAL     :: int(linux.MAdvice.NORMAL)
MEM_ADVICE_RANDOM     :: int(linux.MAdvice.RANDOM)
MEM_ADVICE_SEQUENTIAL :: int(linux.MAdvice.SEQUENTIAL)
MEM_ADVICE_WILL_NEED  :: int(linux.MAdvice.WILLNEED)
MEM_ADVICE_DONT_NEED  :: int(linux.MAdvice.DONTNEED)
MEM_ADVICE_FREE       :: int(linux.MAdvice.FREE)

_mmap :: proc(size: uint, prot: Mem_Protection, flags: Map_Flags, addr: rawptr, fd: Handle, offset: i64) -> ([^]byte, Errno) {
	fd := fd
	if fd == INVALID_HANDLE {
		fd = -1
	}

	ptr, err := linux.mmap(uintptr(addr), size, transmute(linux.Mem_Protection)prot, transmute(linux.Map_Flags)flags, linux.Fd(fd), offset)
	return ([^]byte)(ptr), Errno(err)
}

_munmap :: proc(addr: rawptr, size: uint, _: Map_Flags) -> Errno {
	return Errno(linux.munmap(addr, size))
}

_madvise :: proc(addr: rawptr, size: uint, advice: MAdvice) -> Errno {
	return Errno(linux.madvise(addr, size, linux.MAdvice(advice)))
}
