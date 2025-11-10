#+private
package nbio

import "core:container/queue"
import "core:log"
import "core:net"
import "core:time"
import "core:mem"

import win "core:sys/windows"

// TODO: No WSAGetStatus or whatever, result is directly in the overlapped struct.
// TODO: when calling something like `send` we can directly call WSASend because it is queued, we don't need to queue ourselves too.

__init :: proc(io: ^IO, allocator := context.allocator) -> (err: General_Error) {
	io.allocator = allocator

	mem_err: mem.Allocator_Error
	if mem_err = pool_init(&io.completion_pool, allocator = allocator); mem_err != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { pool_destroy(&io.completion_pool) }

	if mem_err = queue.init(&io.completed, allocator = allocator); mem_err != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { queue.destroy(&io.completed) }

	if io.timeouts, mem_err = make([dynamic]^Completion, allocator); mem_err != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { delete(io.timeouts) }

	// TODO: errors
	io.polls = make_soa(#soa [dynamic]Poll, allocator)

	win.ensure_winsock_initialized()
	defer if err != nil { win.WSACleanup() }

	// TODO: play around with numConcurrentThreads, I believe we want 1, because we already create
	// an IOCP per thread.
	io.iocp = win.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, nil, 0, 0)
	if io.iocp == nil {
		err = General_Error(win.GetLastError())
		return
	}

	return
}

_num_waiting :: proc(io: ^IO) -> int {
	return io.completion_pool.num_waiting
}

__destroy :: proc(io: ^IO) {
	context.allocator = io.allocator

	queue.destroy(&io.completed)
	pool_destroy(&io.completion_pool)
	delete(io.timeouts)
	delete(io.polls)
	win.CloseHandle(io.iocp)
}

_now :: proc(io: ^IO) -> time.Time {
	// TODO:
	return time.now()
}

_tick :: proc(io: ^IO) -> (err: General_Error) {
	// TODO: does this if make sense, at least the polls need to be outside of it?
	if queue.len(io.completed) == 0 {
		next_timeout := flush_timeouts(io)

		// Wait a maximum of a ms if there is nothing to do.
		// TODO: this is pretty naive, a typical server always has accept completions pending and will be at 100% cpu.
		wait_ms: win.DWORD = win.DWORD(IDLE_TIME / time.Millisecond) if io.io_pending == 0 else 0

		// But, to counter inaccuracies in low timeouts,
		// lets make the call exit immediately if the next timeout is close.
		if nt, ok := next_timeout.?; ok && nt <= time.Millisecond * 15 {
			wait_ms = 0
		}

		if len(io.polls) > 0 {
			ret := win.WSAPoll(io.polls.fd, u32(min(int(max(u32)), len(io.polls))), i32(wait_ms))

			if ret > 0 {
				#reverse for &poll, i in io.polls {
					completion := poll.completion
					op := &completion.op.(Op_Poll)
					if poll.fd.revents != 0 {
						context = completion.ctx

						res: Poll_Result
						if poll.fd.revents & win.POLLERR|win.POLLHUP > 0 {
							res = .Error
						} else if poll.fd.revents & win.POLLNVAL > 0 {
							res = .Invalid_Argument
						}

						op.callback(completion.user_data, res)

						if op.multi {
							poll.fd.revents = 0
						} else {
							pool_put(&io.completion_pool, completion)
							unordered_remove_soa(&io.polls, i)
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
		if !win.GetQueuedCompletionStatusEx(io.iocp, &events[0], len(events), &entries_removed, wait_ms, false) {
			if terr := win.GetLastError(); terr != win.WAIT_TIMEOUT {
				err = General_Error(terr)
				return
			}
		}

		// assert(io.io_pending >= int(entries_removed))
		io.io_pending -= int(entries_removed)

		for event in events[:entries_removed] {
			if event.lpOverlapped == nil {
				@static logged: bool
				if !logged {
					log.warn("You have ran into a strange error some users have ran into on Windows 10 but I can't reproduce, I try to recover from the error but please chime in at https://github.com/laytan/odin-http/issues/34")
					logged = true
				}

				io.io_pending += 1
				continue
			}

			// This is actually pointing at the Completion.over field, but because it is the first field
			// It is also a valid pointer to the Completion struct.
			completion := cast(^Completion)event.lpOverlapped
			queue.push_back(&io.completed, completion)
		}
	}

	// Prevent infinite loop when callback adds to completed by storing length.
	n := queue.len(io.completed)
	for _ in 0 ..< n {
		completion := queue.pop_front(&io.completed)
		context = completion.ctx

		handle_completion(io, completion)
	}
	return
}

// Basically a copy of `os.open`, where a flag is added to signal async io, and creation of IOCP.
// Specifically the FILE_FLAG_OVERLAPPEd flag.
_open :: proc(io: ^IO, path: string, flags: File_Flags, perm: int) -> (handle: Handle, err: FS_Error) {
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

	handle_iocp := win.CreateIoCompletionPort(win.HANDLE(handle), io.iocp, 0, 0)
	assert(handle_iocp == io.iocp)

	cmode: byte
	cmode |= FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
	cmode |= FILE_SKIP_SET_EVENT_ON_HANDLE
	if !win.SetFileCompletionNotificationModes(win.HANDLE(handle), cmode) {
		win.CloseHandle(win.HANDLE(handle))
		return INVALID_HANDLE, FS_Error(win.GetLastError())
	}

	return handle, nil
}

_file_size :: proc(_: ^IO, fd: Handle) -> (i64, FS_Error) {
	size: win.LARGE_INTEGER
	ok := win.GetFileSizeEx(win.HANDLE(fd), &size)
	if !ok {
		return 0, FS_Error(win.GetLastError())
	}

	return i64(size), nil
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> (err: net.Listen_Error) {
	if res := win.listen(win.SOCKET(socket), i32(backlog)); res == win.SOCKET_ERROR {
		err = net._listen_error()
	}
	return
}

_open_socket :: proc(
	io: ^IO,
	family: net.Address_Family,
	protocol: net.Socket_Protocol,
) -> (
	socket: net.Any_Socket,
	err: net.Network_Error,
) {
	socket = net.create_socket(family, protocol) or_return

	err = _prepare_socket(io, socket)
	if err != nil { net.close(socket) }
	return
}

_prepare_socket :: proc(io: ^IO, socket: net.Any_Socket) -> net.Network_Error {
	net.set_blocking(socket, false) or_return

	handle := win.HANDLE(uintptr(net.any_socket_to_socket(socket)))

	handle_iocp := win.CreateIoCompletionPort(handle, io.iocp, 0, 0)
	assert(handle_iocp == io.iocp)

	mode: byte
	mode |= FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
	mode |= FILE_SKIP_SET_EVENT_ON_HANDLE
	if !win.SetFileCompletionNotificationModes(handle, mode) {
		return net._socket_option_error()
	}

	return nil
}


_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	return submit(
		io,
		user,
		Op_Accept{
			callback = callback,
			socket   = win.SOCKET(socket),
			client   = win.INVALID_SOCKET,
		},
	)
}

_dial :: proc(io: ^IO, ep: net.Endpoint, user: rawptr, callback: On_Dial) -> (^Completion, net.Network_Error) {
	if ep.port == 0 {
		return nil, net.Dial_Error.Port_Required
	}

	return submit(io, user, Op_Connect{
		callback = callback,
		addr     = endpoint_to_sockaddr(ep),
	}), nil
}

_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) -> ^Completion {
	return submit(io, user, Op_Close{callback = callback, fd = fd})
}

_read :: proc(
	io: ^IO,
	fd: Handle,
	offset: int,
	buf: []byte,
	user: rawptr,
	callback: On_Read,
	all := false,
) -> ^Completion {
	assert(offset >= 0)
	return submit(io, user, Op_Read{
		callback = callback,
		fd       = fd,
		offset   = offset,
		buf      = buf,
		all      = all,
		len      = len(buf),
	})
}

_write :: proc(
	io: ^IO,
	fd: Handle,
	offset: int,
	buf: []byte,
	user: rawptr,
	callback: On_Write,
	all := false,
) -> ^Completion {
	assert(offset >= 0)
	return submit(io, user, Op_Write{
		callback = callback,
		fd       = fd,
		offset   = offset,
		buf      = buf,
		all      = all,
		len      = len(buf),
	})
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv, all := false) -> ^Completion {
	// TODO: implement UDP.
	if _, ok := socket.(net.UDP_Socket); ok { unimplemented("nbio.recv with UDP sockets is not yet implemented") }

	// TODO: support bigger (`int` size)
	assert(len(buf) <= int(max(win.ULONG)))

	return submit(
		io,
		user,
		Op_Recv{
			callback = callback,
			socket   = socket,
			buf      = win.WSABUF{len = win.ULONG(len(buf)), buf = raw_data(buf)},
			all      = all,
			len      = len(buf),
		},
	)
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	endpoint: Maybe(net.Endpoint) = nil,
	all := false,
) -> ^Completion {
	// TODO: implement UDP.
	if _, ok := socket.(net.UDP_Socket); ok { unimplemented("nbio.send with UDP sockets is not yet implemented") }

	// TODO: support bigger (`int` size)
	assert(len(buf) <= int(max(win.ULONG)))

	return submit(
		io,
		user,
		Op_Send{
			callback = callback,
			socket   = socket,
			buf      = win.WSABUF{len = win.ULONG(len(buf)), buf = raw_data(buf)},

			all      = all,
			len      = len(buf),
		},
	)
}

_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.op = Op_Timeout {
		callback = callback,
		expires  = time.time_add(_now(io), dur),
	}
	completion.user_data = user
	completion.ctx = context

	append(&io.timeouts, completion)
	return completion
}

_timeout_completion :: proc(io: ^IO, dur: time.Duration, target: ^Completion) -> ^Completion {
	panic("unimplemented on windows: timeout_completion")
}

_remove :: proc(io: ^IO, target: ^Completion) {
	target.timeout = (^Completion)(TIMED_OUT)

	#partial switch &op in target.op {
	case Op_Poll:
		// TODO: inneficient.
		for poll, i in io.polls {
			if poll.completion == target {
				unordered_remove_soa(&io.polls, i)
				break
			}
		}
		return
	case Op_Timeout, Op_Next_Tick:
		return
	case Op_Remove:
		panic("can't remove a remove")

	// TODO: with timeout_completion we need to remove the target.
	}

	if target.in_kernel {
		handle: win.HANDLE
		switch &op in target.op {
		case Op_Accept:          handle = win.HANDLE(op.socket)
		case Op_Close:
			switch fd in op.fd {
			case net.TCP_Socket: handle = win.HANDLE(uintptr(fd))
			case net.UDP_Socket: handle = win.HANDLE(uintptr(fd))
			case net.Socket:     handle = win.HANDLE(uintptr(fd))
			case Handle:         handle = win.HANDLE(uintptr(fd))
			}
		case Op_Connect:         handle = win.HANDLE(op.socket)
		case Op_Read:            handle = win.HANDLE(op.fd)
		case Op_Write:           handle = win.HANDLE(op.fd)
		case Op_Recv:            handle = win.HANDLE(uintptr(net.any_socket_to_socket(op.socket)))
		case Op_Send:            handle = win.HANDLE(uintptr(net.any_socket_to_socket(op.socket)))
		case Op_Timeout,
		     Op_Next_Tick,
		     Op_Poll,
		     Op_Remove: unreachable()
		}
		ok := win.CancelIoEx(handle, &target.over)
		assert(ok == true) // TODO
	}
}

_next_tick :: proc(io: ^IO, user: rawptr, callback: On_Next_Tick) -> ^Completion {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.op = Op_Next_Tick{
		callback = callback,
	}
	completion.user_data = user

	// TODO: error handling
	queue.push_back(&io.completed, completion)
	return completion
}

_poll :: proc(io: ^IO, socket: net.Any_Socket, event: Poll_Event, multi: bool, user: rawptr, callback: On_Poll) -> ^Completion {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.op = Op_Poll {
		callback = callback,
		multi = multi,
	}
	completion.user_data = user

	winevent: win.c_short
	switch event {
	case .Read:  winevent = win.POLLRDNORM
	case .Write: winevent = win.POLLWRNORM
	}

	append(&io.polls, Poll{
		fd = win.WSA_POLLFD {
			fd     = win.SOCKET(net.any_socket_to_socket(socket)),
			events = winevent,
		},
		completion = completion,
	})
	return completion
}
