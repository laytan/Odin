//+private
package os

import win "core:sys/windows"

MEM_PROT_READ  :: 1
MEM_PROT_WRITE :: 2
MEM_PROT_EXEC  :: 3

// NOTE: madvice is not implemented on Windows.
MEM_ADVICE_NORMAL     :: 1
MEM_ADVICE_RANDOM     :: 2
MEM_ADVICE_SEQUENTIAL :: 3
MEM_ADVICE_WILL_NEED  :: 4
MEM_ADVICE_DONT_NEED  :: 5
MEM_ADVICE_FREE       :: 6

_mmap :: proc(size: uint, prot: Mem_Protection, flags: Map_Flags, addr: rawptr, fd: Handle, offset: i64) -> ([^]byte, Errno) {
	facc: win.DWORD
	fprot: win.DWORD

	sec: win.LPSECURITY_ATTRIBUTES = nil

	if .Shared in flags {
		sec = &win.SECURITY_ATTRIBUTES{
			nLength        = size_of(win.SECURITY_ATTRIBUTES),
			bInheritHandle = true,
		}
	}

	if .Private in flags {
		facc |= win.FILE_MAP_COPY
	}

	if .Write in prot {
		fprot = win.PAGE_READWRITE
		facc |= win.FILE_MAP_WRITE
	}

	if .Read in prot {
		fprot = win.PAGE_READONLY
		facc |= win.FILE_MAP_READ
	}

	if .Exec in prot {
		facc |= win.FILE_MAP_EXECUTE	

		if .Read in prot {
			fprot = win.PAGE_EXECUTE_READ
		} else if .Write in prot {
			fprot = win.PAGE_EXECUTE_READWRITE
		}
	}

	if .Anonymous in flags {
		assert(offset == 0)
		assert(fd == INVALID_HANDLE)

		ptr := win.VirtualAlloc(addr, size, win.MEM_COMMIT|win.MEM_RESERVE, fprot)
		if ptr != nil {
			return ([^]byte)(ptr), ERROR_NONE
		}

		if addr != nil && .Fixed not_in flags {
			ptr := win.VirtualAlloc(nil, size, win.MEM_COMMIT|win.MEM_RESERVE, fprot)
			if ptr != nil {
				return ([^]byte)(ptr), ERROR_NONE
			}
		}

		return nil, Errno(win.GetLastError())
	}

	low     := win.DWORD(size & 0xFFFFFFFF)
	hi      := win.DWORD((size >> 32) & 0xFFFFFFFF)
	mapping := win.CreateFileMappingW(win.HANDLE(fd), sec, fprot, hi, low, nil)
	if mapping == nil {
		return nil, Errno(win.GetLastError())
	}
		
	offlow := win.DWORD(offset & 0xFFFFFFFF)
	offhi  := win.DWORD((size >> 32) & 0xFFFFFFFF)
	ptr    := win.MapViewOfFileEx(mapping, facc, offhi, offlow, size, addr)
	if ptr != nil {
		return ([^]byte)(ptr), ERROR_NONE
	}

	if addr != nil && .Fixed not_in flags {
		ptr := win.MapViewOfFileEx(mapping, facc, offhi, offlow, size, nil)
		if ptr != nil {
			return ([^]byte)(ptr), ERROR_NONE
		}
	}

	return nil, Errno(win.GetLastError())
}

_munmap :: proc(addr: rawptr, size: uint, flags: Map_Flags) -> Errno {
	if .Anonymous in flags {
		if !win.VirtualFree(addr, size, win.MEM_RELEASE) {
			return Errno(win.GetLastError())
		}
	} else {
		if !win.UnmapViewOfFile(addr) {
			return Errno(win.GetLastError())
		}
	}
	return ERROR_NONE
}

_madvise :: proc(addr: rawptr, size: uint, advice: MAdvice) -> Errno {
	// Not implemented on Windows.
	return ERROR_NONE
}
