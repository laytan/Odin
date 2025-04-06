#+private
package nbio

import "base:runtime"

import "core:container/queue"
import "core:fmt"
import "core:mem"
import "core:nbio/uring"
import "core:net"
import "core:sys/linux"

NANOSECONDS_PER_SECOND :: 1e+9

REMOVED :: rawptr(max(uintptr)-1)

// TODO: link_timeout is not enqueued again after a callback requeues because of EINTR or EWOULDBLOCK.

_IO :: struct #no_copy {
	ring:            uring.Ring,
	completion_pool: Pool,
	// Ready to be submitted to kernel, if kernel is full.
	unqueued:        queue.Queue(^Completion),
	// Ready to run callbacks. NOTE: only has next tick events now. shouldn't need a queue for that.
	completed:       queue.Queue(^Completion),
	ios_queued:      u64,
	ios_in_kernel:   u64,
	allocator:       mem.Allocator,
}

_Handle :: linux.Fd

_Completion :: struct {
	result:    i32,
	operation: Operation,
	ctx:       runtime.Context,
	removal:   ^Completion,
	sqe:       ^linux.IO_Uring_SQE,
}

Op_Accept :: struct {
	callback:     On_Accept,
	socket:       net.TCP_Socket,
	sockaddr:     linux.Sock_Addr_Any,
	sockaddr_len: i32,
}

Op_Close :: struct {
	callback: On_Close,
	fd:       linux.Fd,
}

Op_Connect :: struct {
	callback: On_Connect,
	socket:   net.TCP_Socket,
	sockaddr: linux.Sock_Addr_Any,
}

Op_Read :: struct {
	callback: On_Read,
	fd:       linux.Fd,
	buf:      []byte,
	offset:   int,
	all:      bool,
	read:     int,
	len:      int,
}

Op_Write :: struct {
	callback: On_Write,
	fd:       linux.Fd,
	buf:      []byte,
	offset:   int,
	all:      bool,
	written:  int,
	len:      int,
}

Op_Send :: struct {
	endpoint: linux.Sock_Addr_Any,
	callback: On_Sent,
	socket:   net.Any_Socket,
	buf:      []byte,
	len:      int,
	sent:     int,
	all:      bool,
}

Op_Recv :: struct {
	callback: On_Recv,
	socket:   net.Any_Socket,
	buf:      []byte,
	all:      bool,
	received: int,
	len:      int,

	endpoint_out: net.Endpoint,
}

Op_Timeout :: struct {
	callback: On_Timeout,
	expires:  linux.Time_Spec, // NOTE: should prob be absolute, cause we could be queueing it and it doesn't reach the kernel until later.
}

Op_Next_Tick :: struct {
	callback: On_Next_Tick,
}

Op_Poll :: struct {
	callback: On_Poll,
	fd:       linux.Fd,
	event:    Poll_Event,
	multi:    bool,
}

Op_Remove :: struct {
	target: ^Completion,
}

_Op_Link_Timeout :: struct {
	expires: linux.Time_Spec, // NOTE: should prob be absolute, cause we could be queueing it and it doesn't reach the kernel until later.
	target:  ^Completion,
}

flush :: proc(io: ^IO, wait_nr: u32, timeouts: ^uint, etime: ^bool) -> linux.Errno {
	err := flush_submissions(io, wait_nr, timeouts, etime)
	if err != nil { return err }

	err = flush_completions(io, 0, timeouts, etime)
	if err != nil { return err }

	// Store length at this time, so we don't infinite loop if any of the enqueue
	// procs below then add to the queue again.
	n := queue.len(io.unqueued)

	for _ in 0..<n {
		unqueued := queue.pop_front(&io.unqueued)

		if unqueued.removal != nil {
			remove_callback(io, unqueued.removal, &unqueued.removal.operation.(Op_Remove))
			continue
		}

		switch &op in unqueued.operation {
		case Op_Accept:    accept_enqueue (io, unqueued, &op)
		case Op_Close:     close_enqueue  (io, unqueued, &op)
		case Op_Connect:   connect_enqueue(io, unqueued, &op)
		case Op_Read:      read_enqueue   (io, unqueued, &op)
		case Op_Recv:      recv_enqueue   (io, unqueued, &op)
		case Op_Send:      send_enqueue   (io, unqueued, &op)
		case Op_Write:     write_enqueue  (io, unqueued, &op)
		case Op_Timeout:   timeout_enqueue(io, unqueued, &op)
		case Op_Poll:      poll_enqueue   (io, unqueued, &op)
		case Op_Remove:    remove_enqueue (io, unqueued, &op)
		case Op_Next_Tick, _Op_Link_Timeout: unreachable()
		}
	}

	n = queue.len(io.completed)
	for _ in 0 ..< n {
		completed := queue.pop_front(&io.completed)
		context = completed.ctx

		#partial switch &op in completed.operation {
		case Op_Next_Tick: next_tick_callback(io, completed, &op)
		case:              unreachable()
		}
	}

	return nil
}

flush_completions :: proc(io: ^IO, wait_nr: u32, timeouts: ^uint, etime: ^bool) -> linux.Errno {
	cqes: [256]linux.IO_Uring_CQE
	wait_remaining := wait_nr
	for {
		completed := uring.copy_cqes(&io.ring, cqes[:], wait_remaining) or_return

		wait_remaining = max(0, wait_remaining - completed)

		if completed > 0 {
			for cqe in cqes[:completed] {
				io.ios_in_kernel -= 1

				if cqe.user_data == 0 {
					timeouts^ -= 1

					if (-cqe.res == i32(linux.Errno.ETIME)) {
						etime^ = true
					}
					continue
				}

				completed := cast(^Completion)uintptr(cqe.user_data)

				if completed.removal != nil {
					pool_put(&io.completion_pool, completed)
					continue
				}

				completed.result = cqe.res
				context = completed.ctx

				#partial switch &op in completed.operation {
				case Op_Accept:        accept_callback      (io, completed, &op)
				case Op_Close:         close_callback       (io, completed, &op)
				case Op_Connect:       connect_callback     (io, completed, &op)
				case Op_Read:          read_callback        (io, completed, &op)
				case Op_Recv:          recv_callback        (io, completed, &op)
				case Op_Send:          send_callback        (io, completed, &op)
				case Op_Write:         write_callback       (io, completed, &op)
				case Op_Timeout:       timeout_callback     (io, completed, &op)
				case Op_Poll:          poll_callback        (io, completed, &op)
				case Op_Remove:        remove_callback      (io, completed, &op)
				case _Op_Link_Timeout: link_timeout_callback(io, completed, &op)
				case:                  unreachable()
				}
			}
		}

		if completed < len(cqes) { break }
	}

	return nil
}

flush_submissions :: proc(io: ^IO, wait_nr: u32, timeouts: ^uint, etime: ^bool) -> linux.Errno {
	for {
		submitted, err := uring.submit(&io.ring, wait_nr)
		#partial switch err {
		case .NONE:
		case .EINTR:
			continue
		case .ENOMEM:
			ferr := flush_completions(io, 1, timeouts, etime)
			if ferr != nil { return ferr }
			continue
		case:
			return err
		}

		io.ios_queued -= u64(submitted)
		io.ios_in_kernel += u64(submitted)
		break
	}

	return nil
}

enqueue :: proc(io: ^IO, completion: ^Completion, sqe: ^linux.IO_Uring_SQE, ok: bool) {
	if !ok {
		pok, _ := queue.push_back(&io.unqueued, completion)
		if !pok {
			panic("nbio unqueued queue allocation failure")
		}
		return
	}

	completion.sqe = sqe
	io.ios_queued += 1	
}

accept_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	op.sockaddr_len = size_of(op.sockaddr)
	enqueue(io, completion, uring.accept(
		&io.ring,
		u64(uintptr(completion)),
		linux.Fd(op.socket),
		&op.sockaddr,
		&op.sockaddr_len,
		{},
	))
}

accept_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		err: net.Accept_Error
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			accept_enqueue(io, completion, op)
			return
		case .ECANCELED:
			err = .Timeout
		case:
			err = net._accept_error(errno)
		}

		op.callback(completion.user_data, 0, {}, err)
		pool_put(&io.completion_pool, completion)
		return
	}

	client := net.TCP_Socket(completion.result)
	_prepare_socket(client)
	source := sockaddr_storage_to_endpoint(&op.sockaddr)

	op.callback(completion.user_data, client, source, nil)
	pool_put(&io.completion_pool, completion)
}

close_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	enqueue(io, completion, uring.close(
		&io.ring,
		u64(uintptr(completion)),
		op.fd,
	))
}

close_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	errno := linux.Errno(-completion.result)
	op.callback(completion.user_data, FS_Error(errno))
	pool_put(&io.completion_pool, completion)
}

connect_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Connect) {
	enqueue(io, completion, uring.connect(
		&io.ring,
		u64(uintptr(completion)),
		linux.Fd(op.socket),
		&op.sockaddr,
	))
}

connect_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Connect) {
	errno := linux.Errno(-completion.result)
	err: net.Dial_Error
	if errno != nil {
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			connect_enqueue(io, completion, op)
			return
		case .ECANCELED:
			err = .Timeout
		case:
			err = net._dial_error(errno)
		}
		close(op.socket)
	}

	op.callback(completion.user_data, op.socket, err)
	pool_put(&io.completion_pool, completion)
}

read_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Read) {
	enqueue(io, completion, uring.read(
		&io.ring,
		u64(uintptr(completion)),
		op.fd,
		op.buf,
		u64(op.offset),
	))
}

read_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Read) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			read_enqueue(io, completion, op)
		case:
			op.callback(completion.user_data, op.read, FS_Error(errno))
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	op.read += int(completion.result)

	if op.all && op.read < op.len {
		op.buf = op.buf[completion.result:]
		op.offset += int(completion.result)
		read_enqueue(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.read, nil)
	pool_put(&io.completion_pool, completion)
}

recv_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv) {
	switch sock in op.socket {
	case net.TCP_Socket:
		enqueue(io, completion, uring.recv(
			&io.ring,
			u64(uintptr(completion)),
			linux.Fd(sock),
			op.buf,
			{},
		))

	case net.UDP_Socket:
		// TODO: recv from udp is not possible with uring, surely not?

		// NOTE: emulation via poll.
		poll := _poll(io, linux.Fd(sock), .Read, false, completion, proc(completion: rawptr, _: Poll_Event) {
			completion := (^Completion)(completion)
			op         := &completion.operation.(Op_Recv)

			addr: linux.Sock_Addr_Any
			recv, err := linux.recvfrom(linux.Fd(op.socket.(net.UDP_Socket)), op.buf, {}, &addr)
			if err != nil {
				completion.result = -i32(err)
			} else {
				completion.result = i32(recv)
				op.endpoint_out   = sockaddr_storage_to_endpoint(&addr)
			}

			recv_callback(io(), completion, op)
		})
		completion.sqe = poll.sqe
	}
}

recv_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			recv_enqueue(io, completion, op)
			return
		}

		switch cb in op.callback {
		case On_Recv_TCP:
			err: net.TCP_Recv_Error
			#partial switch errno {
			case .ECANCELED:
				err = .Timeout
			case:
				err = net._tcp_recv_error(errno)
			}
			cb(completion.user_data, op.received, err)
		case On_Recv_UDP:
			err: net.UDP_Recv_Error
			#partial switch errno {
			case .ECANCELED:
				err = .Timeout
			case:
				err = net._udp_recv_error(errno)
			}
			cb(completion.user_data, op.received, {}, err)
		}

		pool_put(&io.completion_pool, completion)
		return
	}

	op.received += int(completion.result)

	if op.all && op.received < op.len {
		op.buf = op.buf[completion.result:]
		recv_enqueue(io, completion, op)
		return
	}

	switch cb in op.callback {
	case On_Recv_TCP: cb(completion.user_data, op.received, nil)
	case On_Recv_UDP: cb(completion.user_data, op.received, op.endpoint_out, nil)
	}

	pool_put(&io.completion_pool, completion)
}

send_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	switch sock in op.socket {
	case net.TCP_Socket:
		enqueue(io, completion, uring.send(
			&io.ring,
			u64(uintptr(completion)),
			linux.Fd(sock),
			op.buf,
			{.NOSIGNAL},
		))
	case net.UDP_Socket:
		enqueue(io, completion, uring.sendto(
			&io.ring,
			u64(uintptr(completion)),
			linux.Fd(sock),
			op.buf,
			{.NOSIGNAL},
			&op.endpoint,
		))
	}
}

send_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			send_enqueue(io, completion, op)
			return
		}

		switch cb in op.callback {
		case On_Sent_TCP:
			err: net.TCP_Send_Error
			#partial switch errno {
			case .ECANCELED:
				err = .Timeout
			case:
				err = net._tcp_send_error(errno)
			}
			cb(completion.user_data, op.sent, err)
		case On_Sent_UDP:
			err: net.UDP_Send_Error
			#partial switch errno {
			case .ECANCELED:
				err = .Timeout
			case:
				err = net._udp_send_error(errno)
			}
			cb(completion.user_data, op.sent, err)
		}

		pool_put(&io.completion_pool, completion)
		return
	}

	op.sent += int(completion.result)

	if op.all && op.sent < op.len {
		op.buf = op.buf[completion.result:]
		send_enqueue(io, completion, op)
		return
	}

	switch cb in op.callback {
	case On_Sent_TCP: cb(completion.user_data, op.sent, nil)
	case On_Sent_UDP: cb(completion.user_data, op.sent, nil)
	}
	pool_put(&io.completion_pool, completion)
}

write_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Write) {
	enqueue(io, completion, uring.write(
		&io.ring,
		u64(uintptr(completion)),
		op.fd,
		op.buf,
		u64(op.offset),
	))
}

write_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Write) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			write_enqueue(io, completion, op)
		case:
			op.callback(completion.user_data, op.written, FS_Error(errno))
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	op.written += int(completion.result)

	if op.all && op.written < op.len {
		op.buf = op.buf[completion.result:]
		op.offset += int(completion.result)
		write_enqueue(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.written, nil)
	pool_put(&io.completion_pool, completion)
}

timeout_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Timeout) {
	enqueue(io, completion, uring.timeout(
		&io.ring,
		u64(uintptr(completion)),
		&op.expires,
		0,
		{},
	))
}

timeout_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Timeout) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .ETIME, .ECANCELED: // OK.
		case .EINTR, .EWOULDBLOCK:
			timeout_enqueue(io, completion, op)
			return
		case:
			fmt.panicf("timeout error: %v", errno)
		}
	}

	op.callback(completion.user_data)
	pool_put(&io.completion_pool, completion)
}

next_tick_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Next_Tick) {
	op.callback(completion.user_data)
	pool_put(&io.completion_pool, completion)
}

poll_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Poll) {
	events: linux.Fd_Poll_Events
	switch op.event {
	case .Read:  events = { .IN }
	case .Write: events = { .OUT }
	}

	flags: linux.IO_Uring_Poll_Add_Flags
	if op.multi {
		flags += { .ADD_MULTI }
	}

	enqueue(io, completion, uring.poll_add(
		&io.ring,
		u64(uintptr(completion)),
		op.fd,
		events,
		flags,
	))
}

poll_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Poll) {
	errno := linux.Errno(completion.result)
	#partial switch errno {
	case .NONE:
	case .EINTR, .EWOULDBLOCK:
		if !op.multi {
			poll_enqueue(io, completion, op)
		}
	case .ECANCELED:
		return
	case:
		// TODO: might want to give the user this error.
	}

	op.callback(completion.user_data, op.event)
	if !op.multi {
		pool_put(&io.completion_pool, completion)
	}
}

remove_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Remove) {
	enqueue(io, completion, uring.async_cancel(
		&io.ring,
		u64(uintptr(op.target)),
		u64(uintptr(completion)),
	))
}

remove_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Remove) {
	err := linux.Errno(-completion.result)
	if err != nil && err != .ENOENT {
		fmt.panicf("unexpected nbio.remove() error: %v", err)
	}

	pool_put(&io.completion_pool, completion)
}

link_timeout_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^_Op_Link_Timeout) {
	// If the last op was queued because kernel is full, also queue this op.
	if queue.len(io.unqueued) > 0 && queue.peek_back(&io.unqueued)^ == op.target {
		enqueue(io, completion, nil, false)
		return
	}

	sqe, ok := uring.link_timeout(
		&io.ring,
		u64(uintptr(completion)),
		&op.expires,
		{},
	)
	// If the target wasn't queued, the link timeout should not need to be queued, because uring
	// leaves one spot specifically for a link_timeout.
	assert(ok)

	enqueue(io, completion, sqe, ok)
}

link_timeout_callback :: proc(io: ^IO, completion: ^Completion, op: ^_Op_Link_Timeout) {
	err := linux.Errno(-completion.result)
	if err != nil && err != .ETIME && err != .ECANCELED {
		fmt.panicf("unexpected nbio.link_timeout() error: %v", err)
	}

	pool_put(&io.completion_pool, completion)
}

sockaddr_storage_to_endpoint :: proc(addr: ^linux.Sock_Addr_Any) -> (ep: net.Endpoint) {
	#partial switch addr.family {
	case .INET:
		return net.Endpoint {
			address = net.IP4_Address(addr.sin_addr),
			port    = int(addr.sin_port),
		}
	case .INET6:
		return net.Endpoint {
			address = net.IP6_Address(transmute([8]u16be)addr.sin6_addr),
			port    = int(addr.sin6_port),
		}
	}

	unreachable()
}

endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: linux.Sock_Addr_Any) {
	switch a in ep.address {
	case net.IP4_Address:
		sockaddr.sin_family = .INET
		sockaddr.sin_port = u16be(ep.port)
		sockaddr.sin_addr = cast([4]u8)a
		return
	case net.IP6_Address:
		sockaddr.sin6_family = .INET6
		sockaddr.sin6_port = u16be(ep.port)
		sockaddr.sin6_addr = transmute([16]u8)a
		return
	}

	unreachable()
}
