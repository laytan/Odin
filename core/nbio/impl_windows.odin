#+private file
package nbio

import "core:fmt"
import "core:container/queue"
import "core:container/pool"
import "core:log"
import "core:net"
import "core:time"
import "core:mem"

import win "core:sys/windows"

TIMED_OUT :: rawptr(max(uintptr))
REMOVED   :: rawptr(max(uintptr)-1)

INVALID_HANDLE :: Handle(win.INVALID_HANDLE)

FILE_SKIP_COMPLETION_PORT_ON_SUCCESS :: 0x1
FILE_SKIP_SET_EVENT_ON_HANDLE :: 0x2

MAX_RW :: mem.Gigabyte

// TODO: we may want one iocp per application, and each threads calls GetQueuedblahblah on it.
// Windows seems to have designed it for that use case.
// BUT! I don't think we can then guarantee that a socket is "owned" by a thread, like the other impls do, is that a problem?

@(private="package")
_Event_Loop :: struct /* #no_copy */ {
	iocp:       win.HANDLE,
	allocator:  mem.Allocator,
	timeouts:   [dynamic]^Operation,
	polls:      #soa [dynamic]_Poll,
	completed:  queue.Queue(^Operation),
	io_pending: int,
}

@(private="package")
_Handle :: distinct uintptr

@(private="package")
_Operation :: struct {
	over:      win.OVERLAPPED,
	timeout:   ^Operation,
	in_kernel: bool,
}
#assert(offset_of(Operation, _impl) == 0, "needs to be the first field to work")
#assert(offset_of(_Operation, over) == 0, "needs to be the first field to work")

@(private="package")
_Accept :: struct {
	addr:    win.SOCKADDR_STORAGE_LH,
	pending: bool,
}

@(private="package")
_Close :: struct {}

@(private="package")
_Dial :: struct {
	addr:    win.SOCKADDR_STORAGE_LH,
	pending: bool,
}

@(private="package")
_Read :: struct {
	len:     int,
	pending: bool,
}

@(private="package")
_Write :: struct {}

@(private="package")
_Send :: struct {
	buf:     win.WSABUF,
	pending: bool,
	len:     int,
}

@(private="package")
_Recv :: struct {
	buf:     win.WSABUF,
	pending: bool,
	len:     int,
}

@(private="package")
_Timeout :: struct {
	expires: time.Time,
}

@(private="package")
_Poll :: struct {
	fd:        win.WSA_POLLFD,
	operation: ^Operation,
}

@(private="package")
_Send_File :: struct {}

@(private="package")
_Remove :: struct {}

@(private="package")
_Link_Timeout :: struct {}

@(private="package")
_Splice :: struct {}

// TODO: No WSAGetStatus or whatever, result is directly in the overlapped struct.
// TODO: when calling something like `send` we can directly call WSASend because it is queued, we don't need to queue ourselves too.

@(private="package")
_init :: proc(l: ^Event_Loop, alloc: mem.Allocator) -> (err: General_Error) {
	mem_err: mem.Allocator_Error
	if mem_err = queue.init(&l.completed, allocator = alloc); mem_err != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { queue.destroy(&l.completed) }

	if l.timeouts, mem_err = make([dynamic]^Operation, alloc); mem_err != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { delete(l.timeouts) }

	// TODO: errors
	l.polls = make_soa(#soa [dynamic]_Poll, alloc)

	win.ensure_winsock_initialized()
	defer if err != nil { win.WSACleanup() }

	// TODO: play around with numConcurrentThreads, I believe we want 1, because we already create
	// an IOCP per thread.
	l.iocp = win.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, nil, 0, 0)
	if l.iocp == nil {
		err = General_Error(win.GetLastError())
		return
	}

	return
}

@(private="package")
_destroy :: proc(l: ^Event_Loop) {
	queue.destroy(&l.completed)
	delete(l.timeouts)
	delete(l.polls)
	win.CloseHandle(l.iocp)
}

@(private="package")
__tick :: proc(l: ^Event_Loop) -> (err: General_Error) {

	flush_timeouts :: proc(l: ^Event_Loop) -> (expires: Maybe(time.Duration)) {
		curr: time.Time
		timeout_len := len(l.timeouts)

		// PERF: could use a faster clock, is getting time since program start fast?
		if timeout_len > 0 { curr = now() }

		for i := 0; i < timeout_len; {
			operation := l.timeouts[i]
			cexpires := time.diff(curr, operation.timeout._impl.expires)

			// Timeout done.
			if (cexpires <= 0 || operation._impl.timeout == (^Operation)(REMOVED)) {
				ordered_remove(&l.timeouts, i) // TODO: ordered remove bad.
				queue.push_back(&l.completed, operation)
				timeout_len -= 1
				continue
			}

			// Update minimum timeout.
			exp, ok := expires.?
			expires = min(exp, cexpires) if ok else cexpires

			i += 1
		}
		return
	}

	handle_completed :: proc(op: ^Operation) {
		if !op._impl.in_kernel && op._impl.timeout == (^Operation)(REMOVED) {
			pool.put(&op.l.operation_pool, op)
			return
		}

		completed: bool
		defer if !completed {
			op._impl.in_kernel = true
		}

		#partial switch op.type {
		case .Read:
			read, err := read_callback(op)
			if err == .IO_PENDING {
				op.l.io_pending += 1
				return
			}

			if err == .HANDLE_EOF {
				err = nil
			}

			op.read.read += int(read)

			if err == nil && op.read.all && read > 0 && op.read.read < op.read._impl.len {
				op.read.buf = op.read.buf[read:]
				op.read.offset += int(read)

				op.read._impl.pending = false
				handle_completed(op)
				return
			}

			op.read.err = FS_Error(err)
			op.cb(op)
		case .Send:
			sent, err := send_callback(op)
			if wsa_err_incomplete(err) {
				op.l.io_pending += 1
				return
			}

			op.send.sent += int(sent)

			if err == nil && op.send.all && op.send.sent < op.send._impl.len {
				op.send._impl.buf = win.WSABUF{
					len = op.send._impl.buf.len - win.ULONG(sent),
					buf = ([^]byte)(op.send._impl.buf.buf)[sent:],
				}
				op.send._impl.pending = false
				handle_completed(op)
				return
			}

			op.send.err = err
			op.cb(op)
		case .Close:
			op.close.err = close_callback(op)
			op.cb(op)
		case .Recv:
			received, err := recv_callback(op)
			if wsa_err_incomplete(err) {
				op.l.io_pending += 1
				return
			}

			op.recv.received += int(received)

			if err == nil && op.recv.all && op.recv.received < op.recv._impl.len {
				op.recv._impl.buf = win.WSABUF{
					len = op.recv._impl.buf.len - win.ULONG(received),
					buf = ([^]byte)(op.recv._impl.buf.buf)[received:],
				}
				op.recv._impl.pending = false
				handle_completed(op)
				return
			}

			op.recv.err = err
			op.cb(op)
		case:
			fmt.panicf("unimplemented: %v", op.type)
		}

		completed = true
		pool.put(&op.l.operation_pool, op)
	}

	l.now = time.now()

	// TODO: does this if make sense, at least the polls need to be outside of it?
	if queue.len(l.completed) == 0 {
		next_timeout := flush_timeouts(l)

		// Wait a maximum of a ms if there is nothing to do.
		// TODO: this is pretty naive, a typical server always has accept completions pending and will be at 100% cpu.
		wait_ms: win.DWORD = win.DWORD(IDLE_TIME / time.Millisecond) if l.io_pending == 0 else 0

		// But, to counter inaccuracies in low timeouts,
		// lets make the call exit immediately if the next timeout is close.
		if nt, ok := next_timeout.?; ok && nt <= time.Millisecond * 15 {
			wait_ms = 0
		}

		if len(l.polls) > 0 {
			ret := win.WSAPoll(l.polls.fd, u32(min(int(max(u32)), len(l.polls))), i32(wait_ms))

			if ret > 0 {
				#reverse for &poll, i in l.polls {
					operation := poll.operation
					if poll.fd.revents != 0 {
						context = operation.ctx

						res: Poll_Result
						if poll.fd.revents & win.POLLERR|win.POLLHUP > 0 {
							res = .Error
						} else if poll.fd.revents & win.POLLNVAL > 0 {
							res = .Invalid_Argument
						}

						operation.cb(operation)

						if operation.poll.multi {
							poll.fd.revents = 0
						} else {
							pool.put(&l.operation_pool, operation)
							unordered_remove_soa(&l.polls, i)
						}

						ret -= 1
						if ret == 0 { break }
					}
				}
			}

			// NOTE: Already waited on polls now.
			wait_ms = 0
		}

		events: [256]win.OVERLAPPED_ENTRY
		entries_removed: win.ULONG
		if !win.GetQueuedCompletionStatusEx(l.iocp, &events[0], len(events), &entries_removed, wait_ms, false) {
			if terr := win.GetLastError(); terr != win.WAIT_TIMEOUT {
				err = General_Error(terr)
				return
			}
		}

		// assert(l.io_pending >= int(entries_removed))
		l.io_pending -= int(entries_removed)

		for event in events[:entries_removed] {
			if event.lpOverlapped == nil {
				@static logged: bool
				if !logged {
					log.warn("You have ran into a strange error some users have ran into on Windows 10 but I can't reproduce, I try to recover from the error but please chime in at https://github.com/laytan/odin-http/issues/34")
					logged = true
				}

				l.io_pending += 1
				continue
			}

			// This is actually pointing at the Completion.over field, but because it is the first field
			// It is also a valid pointer to the Completion struct.
			operation := (^Operation)(event.lpOverlapped)
			queue.push_back(&l.completed, operation)
		}
	}

	// Prevent infinite loop when callback adds to completed by storing length.
	n := queue.len(l.completed)
	for _ in 0 ..< n {
		operation := queue.pop_front(&l.completed)
		context = operation.ctx
		handle_completed(operation)
	}
	return
}

@(private="package")
_exec :: proc(op: ^Operation) {
	assert(op.l == &_tls_event_loop)
	queue.push_back(&op.l.completed, op)
}

// Basically a copy of `os.open`, where a flag is added to signal async io, and creation of IOCP.
// Specifically the FILE_FLAG_OVERLAPPEd flag.
@(private="package")
_open :: proc(l: ^Event_Loop, path: string, flags: File_Flags, perm: int) -> (handle: Handle, err: FS_Error) {
	handle = INVALID_HANDLE

	if path == "" {
		err = .Invalid_Argument
		return
	}

	access: u32

	if .Write in flags {
		access |= win.FILE_GENERIC_WRITE
	}

	if .Read in flags {
		access |= win.FILE_GENERIC_READ
	}

	if .Create in flags {
		access |= win.FILE_GENERIC_WRITE
	}
	if .Append in flags {
		access &~= win.FILE_GENERIC_WRITE
		access |= win.FILE_APPEND_DATA
	}

	share_mode := win.FILE_SHARE_READ | win.FILE_SHARE_WRITE
	sa: ^win.SECURITY_ATTRIBUTES = nil
	sa_inherit := win.SECURITY_ATTRIBUTES {
		nLength        = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	if .Inheritable in flags {
		sa = &sa_inherit

	}

	create_mode: u32

	// TODO: this means create and excl are in flags right?
	switch {
	case File_Flags{.Create, .Excl} <= flags:
		create_mode = win.CREATE_NEW
	case File_Flags{.Create, .Trunc} <= flags:
		create_mode = win.CREATE_ALWAYS
	case .Create in flags:
		create_mode = win.OPEN_ALWAYS
	case .Trunc in flags:
		create_mode = win.TRUNCATE_EXISTING
	case:
		create_mode = win.OPEN_EXISTING
	}

	winflags := win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_BACKUP_SEMANTICS

	// This line is the only thing different from the `os.open` procedure.
	// This makes it an asynchronous file that can be used in nbio.
	winflags |= win.FILE_FLAG_OVERLAPPED

	wide_path := win.utf8_to_wstring(path)
	handle = Handle(win.CreateFileW(wide_path, access, share_mode, sa, create_mode, winflags, nil))

	if handle == INVALID_HANDLE {
		err = FS_Error(win.GetLastError())
		return
	}

	// Everything past here is custom/not from `os.open`.

	handle_iocp := win.CreateIoCompletionPort(win.HANDLE(handle), l.iocp, 0, 0)
	assert(handle_iocp == l.iocp)

	cmode: byte
	cmode |= FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
	cmode |= FILE_SKIP_SET_EVENT_ON_HANDLE
	if !win.SetFileCompletionNotificationModes(win.HANDLE(handle), cmode) {
		win.CloseHandle(win.HANDLE(handle))
		return INVALID_HANDLE, FS_Error(win.GetLastError())
	}

	return handle, nil
}

@(private="package")
_file_size :: proc(_: ^Event_Loop, fd: Handle) -> (i64, FS_Error) {
	size: win.LARGE_INTEGER
	ok := win.GetFileSizeEx(win.HANDLE(fd), &size)
	if !ok {
		return 0, FS_Error(win.GetLastError())
	}

	return i64(size), nil
}

@(private="package")
_listen :: proc(socket: TCP_Socket, backlog := 1000) -> (err: net.Listen_Error) {
	if res := win.listen(win.SOCKET(socket), i32(backlog)); res == win.SOCKET_ERROR {
		err = net._listen_error()
	}
	return
}

@(private="package")
_create_socket :: proc(
	l: ^Event_Loop,
	family: net.Address_Family,
	protocol: net.Socket_Protocol,
) -> (
	socket: net.Any_Socket,
	err: net.Network_Error,
) {
	socket = net.create_socket(family, protocol) or_return

	err = _prepare_socket(l, socket)
	if err != nil { net.close(socket) }
	return
}

@(private="package")
_remove :: proc(target: ^Operation) {
	unimplemented()
//	target.timeout = (^Completion)(TIMED_OUT)
//
//	#partial switch &op in target.op {
//	case Op_Poll:
//	// TODO: inneficient.
//		for poll, i in io.polls {
//			if poll.completion == target {
//				unordered_remove_soa(&io.polls, i)
//				break
//			}
//		}
//		return
//	case Op_Timeout, Op_Next_Tick:
//		return
//	case Op_Remove:
//		panic("can't remove a remove")
//
//	// TODO: with timeout_completion we need to remove the target.
//	}
//
//	if target.in_kernel {
//		handle: win.HANDLE
//		switch &op in target.op {
//		case Op_Accept:          handle = win.HANDLE(op.socket)
//		case Op_Close:
//			switch fd in op.fd {
//			case net.TCP_Socket: handle = win.HANDLE(uintptr(fd))
//			case net.UDP_Socket: handle = win.HANDLE(uintptr(fd))
//			case net.Socket:     handle = win.HANDLE(uintptr(fd))
//			case Handle:         handle = win.HANDLE(uintptr(fd))
//			}
//		case Op_Connect:         handle = win.HANDLE(op.socket)
//		case Op_Read:            handle = win.HANDLE(op.fd)
//		case Op_Write:           handle = win.HANDLE(op.fd)
//		case Op_Recv:            handle = win.HANDLE(uintptr(net.any_socket_to_socket(op.socket)))
//		case Op_Send:            handle = win.HANDLE(uintptr(net.any_socket_to_socket(op.socket)))
//		case Op_Timeout,
//		Op_Next_Tick,
//		Op_Poll,
//		Op_Remove: unreachable()
//		}
//		ok := win.CancelIoEx(handle, &target.over)
//		assert(ok == true) // TODO
//	}
}

_prepare_socket :: proc(l: ^Event_Loop, socket: net.Any_Socket) -> net.Network_Error {
	net.set_blocking(socket, false) or_return

	handle := win.HANDLE(uintptr(net.any_socket_to_socket(socket)))

	handle_iocp := win.CreateIoCompletionPort(handle, l.iocp, 0, 0)
	assert(handle_iocp == l.iocp)

	mode: byte
	mode |= FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
	mode |= FILE_SKIP_SET_EVENT_ON_HANDLE
	if !win.SetFileCompletionNotificationModes(handle, mode) {
		return net._socket_option_error()
	}

	return nil
}

//_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
//	return submit(
//		io,
//		user,
//		Op_Accept{
//			callback = callback,
//			socket   = win.SOCKET(socket),
//			client   = win.INVALID_SOCKET,
//		},
//	)
//}
//
//_dial :: proc(io: ^IO, ep: net.Endpoint, user: rawptr, callback: On_Dial) -> (^Completion, net.Network_Error) {
//	if ep.port == 0 {
//		return nil, net.Dial_Error.Port_Required
//	}
//
//	return submit(io, user, Op_Connect{
//		callback = callback,
//		addr     = endpoint_to_sockaddr(ep),
//	}), nil
//}
//
//_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) -> ^Completion {
//	return submit(io, user, Op_Close{callback = callback, fd = fd})
//}

close_callback :: proc(op: ^Operation) -> FS_Error {
	// NOTE: This might cause problems if there is still IO queued/pending.
	// Is that our responsibility to check/keep track of?
	// Might want to call win.CancelloEx to cancel all pending operations first.

	switch h in op.close.subject {
	case Handle:
		if !win.CloseHandle(win.HANDLE(h)) {
			return FS_Error(win.GetLastError())
		}
	case net.TCP_Socket:
		if win.closesocket(win.SOCKET(h)) != win.NO_ERROR {
			return FS_Error(win.WSAGetLastError())
		}
	case net.UDP_Socket:
		if win.closesocket(win.SOCKET(h)) != win.NO_ERROR {
			return FS_Error(win.WSAGetLastError())
		}
	case:
		unreachable()
	}

	return nil
}

//
//_read :: proc(
//	io: ^IO,
//	fd: Handle,
//	offset: int,
//	buf: []byte,
//	user: rawptr,
//	callback: On_Read,
//	all := false,
//) -> ^Completion {
//	assert(offset >= 0)
//	return submit(io, user, Op_Read{
//		callback = callback,
//		fd       = fd,
//		offset   = offset,
//		buf      = buf,
//		all      = all,
//		len      = len(buf),
//	})
//}

read_callback :: proc(op: ^Operation) -> (read: win.DWORD, err: win.System_Error) {
	ok: win.BOOL
	if op.read._impl.pending {
		ok = win.GetOverlappedResult(win.HANDLE(op.read.fd), &op._impl.over, &read, win.FALSE)
	} else {
		op._impl.over.Offset = u32(op.read.offset)
		// TODO: this is wrong.
		op._impl.over.OffsetHigh = op._impl.over.Offset >> 32

		// TODO: MAX_RW?

		ok = win.ReadFile(win.HANDLE(op.read.fd), raw_data(op.read.buf), win.DWORD(len(op.read.buf)), &read, &op._impl.over)

		// Not sure if this also happens with correctly set up handles some times.
		if ok {
			log.info("non-blocking write returned immediately, is the handle set up correctly?")
		}

		op.read._impl.pending = true
	}

	if !ok { err = win.System_Error(win.GetLastError()) }

	return
}

//
//_write :: proc(
//	io: ^IO,
//	fd: Handle,
//	offset: int,
//	buf: []byte,
//	user: rawptr,
//	callback: On_Write,
//	all := false,
//) -> ^Completion {
//	assert(offset >= 0)
//	return submit(io, user, Op_Write{
//		callback = callback,
//		fd       = fd,
//		offset   = offset,
//		buf      = buf,
//		all      = all,
//		len      = len(buf),
//	})
//}
//
//_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv, all := false) -> ^Completion {
//	// TODO: implement UDP.
//	if _, ok := socket.(net.UDP_Socket); ok { unimplemented("nbio.recv with UDP sockets is not yet implemented") }
//
//	// TODO: support bigger (`int` size)
//	assert(len(buf) <= int(max(win.ULONG)))
//
//	return submit(
//		io,
//		user,
//		Op_Recv{
//			callback = callback,
//			socket   = socket,
//			buf      = win.WSABUF{len = win.ULONG(len(buf)), buf = raw_data(buf)},
//			all      = all,
//			len      = len(buf),
//		},
//	)
//}
//
//_send :: proc(
//	io: ^IO,
//	socket: net.Any_Socket,
//	buf: []byte,
//	user: rawptr,
//	callback: On_Sent,
//	endpoint: Maybe(net.Endpoint) = nil,
//	all := false,
//) -> ^Completion {
//	// TODO: implement UDP.
//	if _, ok := socket.(net.UDP_Socket); ok { unimplemented("nbio.send with UDP sockets is not yet implemented") }
//
//	// TODO: support bigger (`int` size)
//	assert(len(buf) <= int(max(win.ULONG)))
//
//	return submit(
//		io,
//		user,
//		Op_Send{
//			callback = callback,
//			socket   = socket,
//			buf      = win.WSABUF{len = win.ULONG(len(buf)), buf = raw_data(buf)},
//
//			all      = all,
//			len      = len(buf),
//		},
//	)
//}

send_callback :: proc(op: ^Operation) -> (sent: win.DWORD, err: net.Send_Error) {
	sock := win.SOCKET(net.any_socket_to_socket(op.send.socket))
	ok: win.BOOL
	if op.send._impl.pending {
		flags: win.DWORD
		ok = win.WSAGetOverlappedResult(sock, &op._impl.over, &sent, win.FALSE, &flags)
	} else {
		// TODO: we have two bufs and a bunch of ints, clean it up.
		if op.send._impl.buf.buf == nil {
			// TODO: support bigger
			assert(len(op.send.buf) < int(max(win.ULONG)))
			op.send._impl.buf = win.WSABUF {
				len = win.ULONG(len(op.send.buf)),
				buf = raw_data(op.send.buf),
			}
			op.send._impl.len = len(op.send.buf)
		}

		buf := op.send._impl.buf
		buf.len = min(buf.len, MAX_RW)

		err_code: win.c_int
		switch _ in op.send.socket {
		case net.TCP_Socket:
			err_code = win.WSASend(sock, &buf, 1, &sent, 0, win.LPWSAOVERLAPPED(&op._impl.over), nil)
		case net.UDP_Socket:
			addr := endpoint_to_sockaddr(op.send.endpoint)
			err_code = win.WSASendTo(sock, &buf, 1, &sent, 0, (^win.sockaddr)(&addr), size_of(addr), win.LPWSAOVERLAPPED(&op._impl.over), nil)
		}

		ok = err_code != win.SOCKET_ERROR
		op.send._impl.pending = true
	}

	if !ok {
		switch _ in op.send.socket {
		case net.TCP_Socket: err = net._tcp_send_error()
		case net.UDP_Socket: err = net._udp_send_error()
		}
 	}
	return
}

recv_callback :: proc(op: ^Operation) -> (received: win.DWORD, err: net.Recv_Error) {
	sock := win.SOCKET(net.any_socket_to_socket(op.recv.socket))
	ok: win.BOOL
	if op.recv._impl.pending {
		flags: win.DWORD
		ok = win.WSAGetOverlappedResult(sock, &op._impl.over, &received, win.FALSE, &flags)
	} else {
	// TODO: we have two bufs and a bunch of ints, clean it up.
		if op.recv._impl.buf.buf == nil {
		// TODO: support bigger
			assert(len(op.recv.buf) < int(max(win.ULONG)))
			op.recv._impl.buf = win.WSABUF {
				len = win.ULONG(len(op.recv.buf)),
				buf = raw_data(op.recv.buf),
			}
			op.recv._impl.len = len(op.recv.buf)
		}

		flags: win.DWORD

		buf := op.recv._impl.buf
		buf.len = min(buf.len, MAX_RW)

		err_code: win.c_int
		switch _ in op.recv.socket {
		case net.TCP_Socket:
			err_code = win.WSARecv(sock, &buf, 1, &received, &flags, win.LPWSAOVERLAPPED(&op._impl.over), nil)
		case net.UDP_Socket:
			addr: win.SOCKADDR_STORAGE_LH
			addr_size := win.c_int(size_of(addr))
			err_code = win.WSARecvFrom(sock, &buf, 1, &received, &flags, (^win.sockaddr)(&addr), &addr_size, win.LPWSAOVERLAPPED(&op._impl.over), nil)
		}

		ok = err_code != win.SOCKET_ERROR
		op.recv._impl.pending = true
	}

	if !ok {
		switch _ in op.recv.socket {
		case net.TCP_Socket: err = net._tcp_recv_error()
		case net.UDP_Socket: err = net._udp_recv_error()
		}
	}
	return
}

//
//_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
//	completion := pool_get(&io.completion_pool)
//
//	completion.op = Op_Timeout {
//		callback = callback,
//		expires  = time.time_add(_now(io), dur),
//	}
//	completion.user_data = user
//	completion.ctx = context
//
//	append(&io.timeouts, completion)
//	return completion
//}
//
//_timeout_completion :: proc(io: ^IO, dur: time.Duration, target: ^Completion) -> ^Completion {
//	panic("unimplemented on windows: timeout_completion")
//}
//
//_next_tick :: proc(io: ^IO, user: rawptr, callback: On_Next_Tick) -> ^Completion {
//	completion := pool_get(&io.completion_pool)
//	completion.ctx = context
//	completion.op = Op_Next_Tick{
//		callback = callback,
//	}
//	completion.user_data = user
//
//	// TODO: error handling
//	queue.push_back(&io.completed, completion)
//	return completion
//}
//
//_poll :: proc(io: ^IO, socket: net.Any_Socket, event: Poll_Event, multi: bool, user: rawptr, callback: On_Poll) -> ^Completion {
//	completion := pool_get(&io.completion_pool)
//	completion.ctx = context
//	completion.op = Op_Poll {
//		callback = callback,
//		multi = multi,
//	}
//	completion.user_data = user
//
//	winevent: win.c_short
//	switch event {
//	case .Read:  winevent = win.POLLRDNORM
//	case .Write: winevent = win.POLLWRNORM
//	}
//
//	append(&io.polls, Poll{
//		fd = win.WSA_POLLFD {
//			fd     = win.SOCKET(net.any_socket_to_socket(socket)),
//			events = winevent,
//		},
//		completion = completion,
//	})
//	return completion
//}

// TODO: this is hacky
wsa_err_incomplete :: proc(err: $T) -> bool {
	when T == net.Send_Error {
		switch e in err {
		case net.UDP_Send_Error: return wsa_err_incomplete(e)
		case net.TCP_Send_Error: return wsa_err_incomplete(e)
		}
	} else when T == net.Recv_Error {
		switch e in err {
		case net.UDP_Recv_Error: return wsa_err_incomplete(e)
		case net.TCP_Recv_Error: return wsa_err_incomplete(e)
		}
	} else when T == net.Dial_Error {
		if err == .Already_Connecting {
			return true
		}
	} else when T != net.Network_Error {
		if err == .Would_Block {
			return true
		} else if err != .Unknown {
			return false
		}
	}

	last := win.System_Error(net.last_platform_error())
	#partial switch last {
	case .WSAEWOULDBLOCK, .IO_PENDING, .IO_INCOMPLETE, .WSAEALREADY: return true
	case: return false
	}
}

// Verbatim copy of private proc in core:net.
endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: win.SOCKADDR_STORAGE_LH) {
	switch a in ep.address {
	case net.IP4_Address:
		(^win.sockaddr_in)(&sockaddr)^ = win.sockaddr_in {
			sin_port   = u16be(win.USHORT(ep.port)),
			sin_addr   = transmute(win.in_addr)a,
			sin_family = u16(win.AF_INET),
		}
		return
	case net.IP6_Address:
		(^win.sockaddr_in6)(&sockaddr)^ = win.sockaddr_in6 {
			sin6_port   = u16be(win.USHORT(ep.port)),
			sin6_addr   = transmute(win.in6_addr)a,
			sin6_family = u16(win.AF_INET6),
		}
		return
	}
	unreachable()
}