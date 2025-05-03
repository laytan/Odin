#+build darwin, freebsd, openbsd, netbsd
#+private
package nbio

import    "base:runtime"

import    "core:container/queue"
import    "core:net"
import    "core:sys/posix"
import    "core:time"
import kq "core:sys/kqueue"

__init :: proc(io: ^IO, allocator := context.allocator) -> (err: General_Error) {
	qerr: posix.Errno
	io.kq, qerr = kq.kqueue()
	if qerr != .NONE {
		return General_Error(qerr)
	}
	defer if err != nil { posix.close(io.kq) }

	perr: runtime.Allocator_Error
	if perr = pool_init(&io.completion_pool); perr != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { pool_destroy(&io.completion_pool) }

	io.timeouts.allocator   = allocator
	io.io_pending.allocator = allocator

	if perr = queue.init(&io.completed, allocator = allocator); perr != nil {
		err = .Allocation_Failed
		return
	}

	return
}

_num_waiting :: proc(io: ^IO) -> int {
	// return abs(sync.atomic_load_explicit(&io.completion_pool.head, .Relaxed) - sync.atomic_load_explicit(&io.completion_pool.tail, .Relaxed))
	return io.completion_pool.num_waiting
}

__destroy :: proc(io: ^IO) {
	delete(io.timeouts)
	delete(io.io_pending)

	queue.destroy(&io.completed)

	posix.close(io.kq)

	pool_destroy(&io.completion_pool)
}

_now :: proc(io: ^IO) -> time.Time {
	return io.now
}

_tick :: proc(io: ^IO) -> General_Error {
	return flush(io)
}

_open :: proc(_: ^IO, path: string, flags: File_Flags, perm: int) -> (handle: Handle, errno: FS_Error) {
	if path == "" {
		errno = .Invalid_Argument
		return
	}

	if len(path) > posix.PATH_MAX {
		errno = .Overflow
		return
	}

	buf: [posix.PATH_MAX+1]byte = ---
	n := copy(buf[:], path)
	buf[n] = 0

	sys_flags := posix.O_Flags{.NOCTTY, .CLOEXEC, .NONBLOCK}

	if .Write in flags {
		if .Read in flags {
			sys_flags += {.RDWR}
		} else {
			sys_flags += {.WRONLY}
		}
	}

	if .Append      in flags { sys_flags += {.APPEND} }
	if .Create      in flags { sys_flags += {.CREAT} }
	if .Excl        in flags { sys_flags += {.EXCL} }
	if .Sync        in flags { sys_flags += {.DSYNC} }
	if .Trunc       in flags { sys_flags += {.TRUNC} }
	if .Inheritable in flags { sys_flags -= {.CLOEXEC} }

	handle = posix.open(cstring(raw_data(buf[:])), sys_flags, transmute(posix.mode_t)posix._mode_t(perm))
	if handle < 0 {
		errno = FS_Error(posix.errno())
	}

	return
}

// // TODO: public `prepare_handle` and `prepare_socket` to take in a handle/socket from some other source?
// // (If that is possible on Windows).
// _prepare_handle :: proc(fd: Handle) -> FS_Error {
// 	res := posix.fcntl(fd, .GETFL, uintptr(0))
// 	if res < 0 {
// 		return FS_Error(posix.errno())
// 	}
//
// 	flags := transmute()
// }

_file_size :: proc(_: ^IO, fd: Handle) -> (i64, FS_Error) {
	stat: posix.stat_t
	if posix.fstat(fd, &stat) != .OK {
		return 0, FS_Error(posix.errno())
	}

	if posix.S_ISREG(stat.st_mode) {
		return i64(stat.st_size), nil
	}

	return 0, .Invalid_Argument
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Listen_Error {
	if res := posix.listen(posix.FD(socket), i32(backlog)); res != .OK {
		return net.Listen_Error(posix.errno())
	}

	return nil
}

prep_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx       = context
	completion.user_data = user
	completion.operation = Op_Accept{
		callback = callback,
		sock     = socket,
	}

	return completion
}

execute :: proc(completion: ^Completion) {
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	completion := prep_accept(io, socket, user, callback)
	execute(completion)
	return completion
}

_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx       = context
	completion.user_data = user

	completion.operation = Op_Close{
		callback = callback,
	}
	op := &completion.operation.(Op_Close)

	switch h in fd {
	case net.TCP_Socket: op.handle = Handle(h)
	case net.UDP_Socket: op.handle = Handle(h)
	case net.Socket:     op.handle = Handle(h)
	case Handle:         op.handle = h
	}

	push_completed(io, completion)
	return completion
}

_dial :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Dial) -> (completion: ^Completion, err: net.Network_Error) {
	if endpoint.port == 0 {
		return nil, net.Dial_Error.Port_Required
	}

	sock: net.Any_Socket
	sock, err = net.create_socket(net.family_from_endpoint(endpoint), .TCP)
	if err != nil {
		return
	}

	if err = _prepare_socket(sock); err != nil {
		_close(io, net.any_socket_to_socket(sock), nil, empty_on_close)
		return
	}

	completion = pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Connect {
		callback = callback,
		socket   = sock.(net.TCP_Socket),
		sockaddr = _endpoint_to_sockaddr(endpoint),
	}

	push_completed(io, completion)
	return
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
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Read {
		callback = callback,
		fd       = fd,
		buf      = buf,
		offset   = offset,
		all      = all,
		len      = len(buf),
	}

	push_completed(io, completion)
	return completion
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv, all := false) -> ^Completion {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Recv {
		callback = callback,
		socket   = socket,
		buf      = buf,
		all      = all,
		len      = len(buf),
	}

	push_completed(io, completion)
	return completion
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
	if _, ok := socket.(net.UDP_Socket); ok {
		assert(endpoint != nil, "send on UDP socket requires endpoint to send to")
	}

	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Send {
		callback = callback,
		socket   = socket,
		buf      = buf,
		endpoint = endpoint,
		all      = all,
		len      = len(buf),
	}

	push_completed(io, completion)
	return completion
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
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Write {
		callback = callback,
		fd       = fd,
		buf      = buf,
		offset   = offset,
		all      = all,
		len      = len(buf),
	}

	push_completed(io, completion)
	return completion
}

// Runs the callback after the timeout, using the kqueue.
_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Timeout {
		callback = callback,
		expires  = time.time_add(io.now, dur),
	}

	push_timeout(io, completion)
	return completion
}

INTERNAL_TIMEOUT :: rawptr(max(uintptr))

// TODO: We could have completions hold a pointer to the IO so it doesn't need to be passed here.
_timeout_completion :: proc(io: ^IO, dur: time.Duration, target: ^Completion) -> ^Completion {
	assert(target != nil)

	#partial switch _ in target.operation {
	case Op_Timeout, Op_Next_Tick, Op_Remove: panic("trying to add a timeout to an operation that can't timeout")
	}

	completion := pool_get(&io.completion_pool)
	completion.user_data = target
	completion.operation = Op_Timeout {
		callback = cast(On_Timeout)INTERNAL_TIMEOUT,
		expires = time.time_add(io.now, dur),
	}
	target.timeout = completion

	push_timeout(io, completion)
	return completion
}

_remove :: proc(io: ^IO, target: ^Completion) {
	assert(target != nil)

	#partial switch &op in target.operation {
	case Op_Timeout:
		op.expires = { _nsec = -1 }
		target.timeout = (^Completion)(REMOVED)

		if op.callback == cast(On_Timeout)INTERNAL_TIMEOUT {
			_remove(io, (^Completion)(target.user_data))
		}

		return
	case Op_Remove:
		panic("can't remove a remove event")
	}

	if !target.in_kernel {
		target.timeout = (^Completion)(REMOVED)
		return
	}

	completion := pool_get(&io.completion_pool)
	completion.operation = Op_Remove {
		target = target,
	}

	push_pending(io, completion)
}

_next_tick :: proc(io: ^IO, user: rawptr, callback: On_Next_Tick) -> ^Completion {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Next_Tick {
		callback = callback,
	}

	push_completed(io, completion)
	return completion
}

_poll :: proc(io: ^IO, socket: net.Any_Socket, event: Poll_Event, multi: bool, user: rawptr, callback: On_Poll) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Poll{
		callback = callback,
		fd       = cast(Handle)net.any_socket_to_socket(socket),
		event    = event,
		multi    = multi,
	}

	push_pending(io, completion)
	return completion
}
