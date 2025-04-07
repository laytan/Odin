#+private
package nbio

import "core:container/queue"
import "core:nbio/uring"
import "core:net"
import "core:sys/linux"
import "core:time"

// TODO: use uring.link_timeout for with_timeout

__init :: proc(io: ^IO, alloc := context.allocator) -> (err: General_Error) {
	io.allocator = alloc

	if perr := pool_init(&io.completion_pool, allocator = alloc); perr != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { pool_destroy(&io.completion_pool) }

	params := uring.DEFAULT_PARAMS

	ENTRIES :: 256
	uerr := uring.init(&io.ring, &params, ENTRIES)
	if uerr != nil {
		err = General_Error(uerr)
		return
	}
	defer if err != nil { uring.destroy(&io.ring) }

	if perr := queue.init(&io.unqueued, allocator = alloc); perr != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { queue.destroy(&io.unqueued) }

	if perr := queue.init(&io.completed, allocator = alloc); perr != nil {
		err = .Allocation_Failed
		return
	}

	return
}

_num_waiting :: proc(io: ^IO) -> int {
	return io.completion_pool.num_waiting
}

__destroy :: proc(io: ^IO) {
	context.allocator = io.allocator

	queue.destroy(&io.unqueued)
	queue.destroy(&io.completed)
	pool_destroy(&io.completion_pool)
	uring.destroy(&io.ring)
}

_now :: proc(io: ^IO) -> time.Time {
	return io.now
}

_tick :: proc(io: ^IO) -> (err: General_Error) {
	return General_Error(flush(io))
}

_open :: proc(_: ^IO, path: string, flags: File_Flags, perm: int) -> (handle: Handle, err: FS_Error) {
	if path == "" {
		err = .Invalid_Argument
		return
	}

	// TODO: arbitrarily long paths.
	PATH_MAX :: 4096

	if len(path) > PATH_MAX {
		err = .Overflow
		return
	}

	buf: [PATH_MAX+1]byte = ---
	n := copy(buf[:], path)
	buf[n] = 0

	sys_flags := linux.Open_Flags{.NOCTTY, .CLOEXEC, .NONBLOCK}

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

	errno: linux.Errno
	handle, errno = linux.open(cstring(raw_data(buf[:])), sys_flags, transmute(linux.Mode)i32(perm))
	if errno != nil {
		err = FS_Error(errno)
	}

	return
}

_file_size :: proc(_: ^IO, fd: Handle) -> (i64, FS_Error) {
	s: linux.Stat
	errno := linux.fstat(fd, &s)
	if errno != nil {
		return 0, FS_Error(errno)
	}

	if linux.S_ISREG(s.mode) {
		return i64(s.size), nil
	}

	return 0, .Invalid_Argument
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Listen_Error {
	err := linux.listen(linux.Fd(socket), i32(backlog))
	if err != nil {
		return net._listen_error(err)
	}
	return nil
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Accept {
		callback = callback,
		socket   = socket,
	}

	accept_enqueue(io, completion, &completion.operation.(Op_Accept))
	return completion
}

_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user

	handle: linux.Fd
	switch h in fd {
	case net.TCP_Socket: handle = linux.Fd(h)
	case net.UDP_Socket: handle = linux.Fd(h)
	case net.Socket:     handle = linux.Fd(h)
	case Handle:         handle = h
	}

	completion.operation = Op_Close {
		callback = callback,
		fd       = handle,
	}

	close_enqueue(io, completion, &completion.operation.(Op_Close))
	return completion
}

_dial :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Dial) -> (^Completion, net.Network_Error) {
	if endpoint.port == 0 {
		return nil, net.Dial_Error.Port_Required
	}

	family := net.family_from_endpoint(endpoint)
	sock, err := net.create_socket(family, .TCP)
	if err != nil {
		return nil, err
	}

	if preperr := _prepare_socket(sock); err != nil {
		close(net.any_socket_to_socket(sock))
		return nil, preperr
	}

	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Connect {
		callback = callback,
		socket   = sock.(net.TCP_Socket),
		sockaddr = endpoint_to_sockaddr(endpoint),
	}

	connect_enqueue(io, completion, &completion.operation.(Op_Connect))
	return completion, nil
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

	read_enqueue(io, completion, &completion.operation.(Op_Read))
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

	recv_enqueue(io, completion, &completion.operation.(Op_Recv))
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
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Send {
		callback = callback,
		socket   = socket,
		buf      = buf,
		all      = all,
		len      = len(buf),
	}

	if _, ok := socket.(net.UDP_Socket); ok {
		(&completion.operation.(Op_Send)).endpoint = endpoint_to_sockaddr(endpoint.?)
	}

	send_enqueue(io, completion, &completion.operation.(Op_Send))
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
	assert(offset >= 0)

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

	write_enqueue(io, completion, &completion.operation.(Op_Write))
	return completion
}

_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user

	nsec := time.duration_nanoseconds(dur)
	completion.operation = Op_Timeout {
		callback = callback,
		expires = linux.Time_Spec{
			time_sec  = uint(nsec / NANOSECONDS_PER_SECOND),
			time_nsec = uint(nsec % NANOSECONDS_PER_SECOND),
		},
	}

	timeout_enqueue(io, completion, &completion.operation.(Op_Timeout))
	return completion
}

_timeout_completion :: proc(io: ^IO, dur: time.Duration, target: ^Completion) -> ^Completion {
	target.sqe.flags += {.IO_LINK}

	completion := pool_get(&io.completion_pool)
	completion.ctx = context

	nsec := time.duration_nanoseconds(dur)
	completion.operation = _Op_Link_Timeout {
		target = target,
		expires = linux.Time_Spec {
			time_sec  = uint(nsec / NANOSECONDS_PER_SECOND),
			time_nsec = uint(nsec % NANOSECONDS_PER_SECOND),
		},
	}

	link_timeout_enqueue(io, completion, &completion.operation.(_Op_Link_Timeout))
	return completion
}

_remove :: proc(io: ^IO, target: ^Completion) {
	target := target
	assert(target != nil)

	#partial switch &op in target.operation {
	case Op_Remove:
		panic("can't remove a remove event")
	case _Op_Link_Timeout: 
		target = op.target
	}

	completion := pool_get(&io.completion_pool)
	completion.ctx = context

	completion.operation = Op_Remove {
		target = target,
	}

	target.removal = completion

	remove_enqueue(io, completion, &completion.operation.(Op_Remove))
}

_next_tick :: proc(io: ^IO, user: rawptr, callback: On_Next_Tick) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user

	completion.operation = Op_Next_Tick {
		callback = callback,
	}

	queue.push_back(&io.completed, completion)
	return completion
}

_poll :: proc(io: ^IO, fd: Handle, event: Poll_Event, multi: bool, user: rawptr, callback: On_Poll) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user

	completion.operation = Op_Poll{
		callback = callback,
		fd       = fd,
		event    = event,
		multi    = multi,
	}

	poll_enqueue(io, completion, &completion.operation.(Op_Poll))
	return completion
}
