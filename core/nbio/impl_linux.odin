#+private
package nbio

import "core:container/queue"
import "core:nbio/uring"
import "core:net"
import "core:sys/linux"
import "core:time"

// TODO: use uring.link_timeout for with_timeout

_init :: proc(io: ^IO, alloc := context.allocator) -> (err: General_Error) {
	io.allocator = alloc

	if perr := pool_init(&io.completion_pool, allocator = alloc); err != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { pool_destroy(&io.completion_pool) }

	params := uring.DEFAULT_PARAMS

	// Make read, write etc. increment and use the file cursor.
	params.features += {.RW_CUR_POS}

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

_destroy :: proc(io: ^IO) {
	context.allocator = io.allocator

	queue.destroy(&io.unqueued)
	queue.destroy(&io.completed)
	pool_destroy(&io.completion_pool)
	uring.destroy(&io.ring)
}

_now :: proc(io: ^IO) -> time.Time {
	// TODO:
	return time.now()
}

_tick :: proc(io: ^IO) -> (err: General_Error) {
	timeouts: uint = 0
	etime := false

	t, lerr := linux.clock_gettime(.MONOTONIC) // TODO: should it be raw?
	if lerr != nil {
		err = General_Error(lerr)
		return
	}

	t.time_nsec += uint(IDLE_TIME)

	// TODO: you can actually give the io_uring_enter syscall a timeout, instead of doing it manually here.

	for !etime {
		// Queue the timeout, if there is an error, flush (cause its probably full) and try again.
		if _, ok := uring.timeout(&io.ring, 0, &t, 1, { .ABS }); !ok {
			if errno := flush_submissions(io, 0, &timeouts, &etime); errno != nil {
				return General_Error(errno)
			}

			if _, ok := uring.timeout(&io.ring, 0, &t, 1, { .ABS }); !ok {
				return .Allocation_Failed
			}
		}

		timeouts += 1
		io.ios_queued += 1

		ferr := flush(io, 1, &timeouts, &etime)
		if ferr != nil { return General_Error(ferr) }
	}

	for timeouts > 0 {
		fcerr := flush_completions(io, 0, &timeouts, &etime)
		if fcerr != nil { return General_Error(fcerr) }
	}

	return nil
}

_open :: proc(_: ^IO, path: string, flags: File_Flags, perm: int) -> (handle: Handle, err: FS_Error) {
	unimplemented()
}

_file_size :: proc(_: ^IO, fd: Handle) -> (i64, FS_Error) {
	unimplemented()
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Network_Error {
	err := linux.listen(linux.Fd(socket), i32(backlog))
	return net.Listen_Error(err)
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

_connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) -> (^Completion, net.Network_Error) {
	if endpoint.port == 0 {
		return nil, net.Dial_Error.Port_Required
	}

	family := net.family_from_endpoint(endpoint)
	sock, err := net.create_socket(family, .TCP)
	if err != nil {
		return nil, err
	}

	if preperr := _prepare_socket(sock); err != nil {
		close(io, net.any_socket_to_socket(sock))
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
	_: Maybe(net.Endpoint) = nil,
	all := false,
) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	// TODO: UDP

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Send {
		callback = callback,
		socket   = socket,
		buf      = buf,
		all      = all,
		len      = len(buf),
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
	unimplemented()
}

_remove :: proc(io: ^IO, target: ^Completion) {
	unimplemented()
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
