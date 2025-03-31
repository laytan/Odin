#+private
package nbio

import "base:runtime"

import "core:c"
import "core:container/queue"
import "core:fmt"
import "core:mem"
import "core:nbio/uring"
import "core:net"
import "core:sys/linux"

NANOSECONDS_PER_SECOND :: 1e+9

_IO :: struct #no_copy {
	ring:            uring.Ring,
	completion_pool: Pool,
	// Ready to be submitted to kernel.
	unqueued:        queue.Queue(^Completion),
	// Ready to run callbacks.
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
}

Op_Accept :: struct {
	callback:    On_Accept,
	socket:      net.TCP_Socket,
	sockaddr:    linux.Sock_Addr_Any,
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
}

Op_Timeout :: struct {
	callback: On_Timeout,
	expires:  linux.Time_Spec,
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
		switch &op in unqueued.operation {
		case Op_Accept:      accept_enqueue (io, unqueued, &op)
		case Op_Close:       close_enqueue  (io, unqueued, &op)
		case Op_Connect:     connect_enqueue(io, unqueued, &op)
		case Op_Read:        read_enqueue   (io, unqueued, &op)
		case Op_Recv:        recv_enqueue   (io, unqueued, &op)
		case Op_Send:        send_enqueue   (io, unqueued, &op)
		case Op_Write:       write_enqueue  (io, unqueued, &op)
		case Op_Timeout:     timeout_enqueue(io, unqueued, &op)
		case Op_Poll:        poll_enqueue   (io, unqueued, &op)
		case Op_Next_Tick:   unreachable()
		}
	}

	n = queue.len(io.completed)
	for _ in 0 ..< n {
		completed := queue.pop_front(&io.completed)
		context = completed.ctx

		switch &op in completed.operation {
		case Op_Accept:      accept_callback   (io, completed, &op)
		case Op_Close:       close_callback    (io, completed, &op)
		case Op_Connect:     connect_callback  (io, completed, &op)
		case Op_Read:        read_callback     (io, completed, &op)
		case Op_Recv:        recv_callback     (io, completed, &op)
		case Op_Send:        send_callback     (io, completed, &op)
		case Op_Write:       write_callback    (io, completed, &op)
		case Op_Timeout:     timeout_callback  (io, completed, &op)
		case Op_Poll:        poll_callback     (io, completed, &op)
		case Op_Next_Tick:   next_tick_callback(io, completed, &op)
		case: unreachable()
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
			if err := queue.reserve(&io.completed, int(completed)); err != nil {
				return .ENOMEM
			}

			for cqe in cqes[:completed] {
				io.ios_in_kernel -= 1

				if cqe.user_data == 0 {
					timeouts^ -= 1

					if (-cqe.res == i32(linux.Errno.ETIME)) {
						etime^ = true
					}
					continue
				}

				completion := cast(^Completion)uintptr(cqe.user_data)
				completion.result = cqe.res

				ok, _ := queue.push_back(&io.completed, completion)
				assert(ok) // Reserved above.
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

enqueue :: proc(io: ^IO, completion: ^Completion, ok: bool) {
	if !ok {
		pok, _ := queue.push_back(&io.unqueued, completion)
		if !pok {
			panic("nbio unqueued queue allocation failure")
		}
		return
	}

	io.ios_queued += 1	
}

accept_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	_, ok := uring.accept(
		&io.ring,
		u64(uintptr(completion)),
		linux.Fd(op.socket),
		&op.sockaddr,
		{},
	)
	enqueue(io, completion, ok)
}

accept_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			accept_enqueue(io, completion, op)
		case:
			op.callback(completion.user_data, 0, {}, net.Accept_Error(errno))
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	client := net.TCP_Socket(completion.result)
	err    := _prepare_socket(client)
	source := sockaddr_storage_to_endpoint(&op.sockaddr)

	op.callback(completion.user_data, client, source, (^net.Accept_Error)(&err)^)
	pool_put(&io.completion_pool, completion)
}

close_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	_, ok := uring.close(&io.ring, u64(uintptr(completion)), op.fd)
	enqueue(io, completion, ok)
}

close_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	errno := linux.Errno(-completion.result)
	op.callback(completion.user_data, FS_Error(errno))
	pool_put(&io.completion_pool, completion)
}

connect_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Connect) {
	_, ok := uring.connect(
		&io.ring,
		u64(uintptr(completion)),
		linux.Fd(op.socket),
		&op.sockaddr,
	)
	enqueue(io, completion, ok)
}

connect_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Connect) {
	errno := linux.Errno(-completion.result)
	#partial switch errno {
	case .EINTR, .EWOULDBLOCK:
		connect_enqueue(io, completion, op)
		return
	case .NONE:
		op.callback(completion.user_data, op.socket, nil)
	case:
		close(op.socket)
		op.callback(completion.user_data, {}, net.Dial_Error(errno))
	}
	pool_put(&io.completion_pool, completion)
}

read_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Read) {
	_, ok := uring.read(&io.ring, u64(uintptr(completion)), op.fd, op.buf, u64(op.offset))
	enqueue(io, completion, ok)
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
	tcpsock, is_tcp := op.socket.(net.TCP_Socket)
	if !is_tcp {
		// TODO: figure out and implement.
		unimplemented("UDP recv is unimplemented for linux nbio")
	}

	_, ok := uring.recv(&io.ring, u64(uintptr(completion)), linux.Fd(tcpsock), op.buf, {})
	enqueue(io, completion, ok)
}

recv_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			recv_enqueue(io, completion, op)
		case:
			op.callback.(On_Recv_TCP)(completion.user_data, op.received, net.TCP_Recv_Error(errno))
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	op.received += int(completion.result)

	if op.all && op.received < op.len {
		op.buf = op.buf[completion.result:]
		recv_enqueue(io, completion, op)
		return
	}

	op.callback.(On_Recv_TCP)(completion.user_data, op.received, nil)
	pool_put(&io.completion_pool, completion)
}

send_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	tcpsock, is_tcp := op.socket.(net.TCP_Socket)
	if !is_tcp {
		// TODO: figure out and implement.
		unimplemented("UDP send is unimplemented for linux nbio")
	}

	_, ok := uring.send(&io.ring, u64(uintptr(completion)), linux.Fd(tcpsock), op.buf, {.NOSIGNAL})
	enqueue(io, completion, ok)
}

send_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			send_enqueue(io, completion, op)
		case .EPIPE:
			errno = .ECONNRESET
			fallthrough
		case:
			// TODO: could be a DNS socket / error.
			op.callback.(On_Sent_TCP)(completion.user_data, op.sent, net.TCP_Send_Error(errno))
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	op.sent += int(completion.result)

	if op.all && op.sent < op.len {
		op.buf = op.buf[completion.result:]
		send_enqueue(io, completion, op)
		return
	}

	op.callback.(On_Sent_TCP)(completion.user_data, op.sent, nil)
	pool_put(&io.completion_pool, completion)
}

write_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Write) {
	_, ok := uring.write(&io.ring, u64(uintptr(completion)), op.fd, op.buf, u64(op.offset))
	enqueue(io, completion, ok)
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
	_, ok := uring.timeout(&io.ring, u64(uintptr(completion)), &op.expires, 0, {})
	enqueue(io, completion, ok)
}

timeout_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Timeout) {
	if completion.result < 0 {
		errno := linux.Errno(-completion.result)
		#partial switch errno {
		case .ETIME: // OK.
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

	_, ok := uring.poll_add(&io.ring, u64(uintptr(completion)), op.fd, events, flags)
	enqueue(io, completion, ok)
}

poll_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Poll) {
	op.callback(completion.user_data, op.event)
	if !op.multi {
		pool_put(&io.completion_pool, completion)
	}
}

sockaddr_storage_to_endpoint :: proc(addr: ^linux.Sock_Addr_Any) -> (ep: net.Endpoint) {
	#partial switch addr.family {
	case .INET:
		ep = net.Endpoint {
			address = net.IP4_Address(transmute([4]byte) addr.sin_addr),
			port    = int(addr.sin_port),
		}
	case .INET6:
		ep = net.Endpoint {
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
		sockaddr.sin_addr = transmute([4]u8)a
		return
	case net.IP6_Address:
		sockaddr.sin6_family = .INET6
		sockaddr.sin6_port = u16be(ep.port)
		sockaddr.sin6_addr = transmute([16]u8)a
		return
	}

	unreachable()
}
