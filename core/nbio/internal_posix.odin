#+build darwin, freebsd, netbsd, openbsd
#+private
package nbio

import    "base:runtime"

import    "core:container/queue"
import    "core:net"
import    "core:sys/posix"
import    "core:time"
import    "core:mem"
import kq "core:sys/kqueue"

MAX_RW :: mem.Gigabyte

MAX_EVENTS :: 256

TIMED_OUT :: rawptr(max(uintptr))
REMOVED   :: rawptr(max(uintptr)-1)

_IO :: struct #no_copy {
	kq:              kq.KQ,
	io_inflight:     int,
	completion_pool: Pool,
	timeouts:        [dynamic]^Completion,
	completed:       queue.Queue(^Completion),
	io_pending:      [dynamic]^Completion,
	now:             time.Time,
}

_Handle :: posix.FD

_Completion :: struct {
	timeout:   ^Completion,
	in_kernel: bool,
}

_Op_Accept :: struct {}

_Op_Close :: struct {}

_Op_Connect :: struct {
	sockaddr:  posix.sockaddr_storage,
	initiated: bool,
}

_Op_Recv :: struct {}

_Op_Send :: struct {}

_Op_Read :: struct {}

_Op_Write :: struct {}

_Op_Timeout :: struct {}

_Op_Next_Tick :: struct {}

_Op_Poll :: struct {}

_Op_Remove :: struct {}

push_completed :: proc(io: ^IO, completed: ^Completion) {
	ok, err := queue.push_back(&io.completed, completed)
	if !ok || err != nil {
		panic("nbio completed queue allocation failure")
	}
}

push_timeout :: proc(io: ^IO, completion: ^Completion) {
	when !ODIN_DISABLE_ASSERT {
		_, is_timeout := completion.operation.(Op_Timeout)
		assert(is_timeout)
	}

	_, err := append(&io.timeouts, completion)
	if err != nil {
		panic("nbio timeout queue allocation failure")
	}
}

push_pending :: proc(io: ^IO, completion: ^Completion) {
	_, err := append(&io.io_pending, completion)
	if err != nil {
		panic("nbio pending queue allocation failure")
	}
}

flush :: proc(io: ^IO) -> General_Error {
	defer assert(io.io_inflight >= 0)

	events: [MAX_EVENTS]kq.KEvent

	min_timeout := flush_timeouts(io)
	change_events, completions_flushed := flush_io(io, events[:])
	// PERF: this is ordered and O(N), can this be made unordered?
	remove_range(&io.io_pending, 0, completions_flushed)

	if (change_events > 0 || queue.len(io.completed) == 0) {
		if (change_events == 0 && queue.len(io.completed) == 0 && io.io_inflight == 0) {
			return nil
		}

		max_timeout := IDLE_TIME
		timeout: posix.timespec
		timeout.tv_nsec = min(min_timeout.? or_else i64(max_timeout), i64(max_timeout))
		new_events: i32
		for {
			err: posix.Errno
			new_events, err = kq.kevent(io.kq, events[:change_events], events[:], &timeout)
			if err == .EINTR {
				continue
			} else if err != nil {
				return General_Error(err)
			} else {
				break
			}
		}

		// TODO: does removal return a response, because this would be wrong otherwise?
		io.io_inflight += change_events
		io.io_inflight -= int(new_events)

		assert(io.io_inflight >= 0)
		assert(new_events >= 0)

		queue.reserve(&io.completed, int(new_events))
		for event in events[:new_events] {
			completion := cast(^Completion)event.udata

			// TODO: handle the .Error flag and pass it through to the user, maybe only needed for poll
			// because the others we just try the operation again?

			completion.in_kernel = false
			push_completed(io, completion)
		}
	}

	// Save length so we avoid an infinite loop when there is added to the queue in a callback.
	n := queue.len(io.completed)
	for _ in 0 ..< n {
		completed := queue.pop_front(&io.completed)
		context = completed.ctx

		if completed.timeout == (^Completion)(REMOVED) {
			pool_put(&io.completion_pool, completed)
			continue
		} else if completed.timeout == (^Completion)(TIMED_OUT) {
			time_out_op(io, completed)
			pool_put(&io.completion_pool, completed)
			continue
		}

		switch &op in completed.operation {
		case Op_Accept:      do_accept     (io, completed, &op)
		case Op_Close:       do_close      (io, completed, &op)
		case Op_Connect:     do_connect    (io, completed, &op)
		case Op_Read:        do_read       (io, completed, &op)
		case Op_Recv:        do_recv       (io, completed, &op)
		case Op_Send:        do_send       (io, completed, &op)
		case Op_Write:       do_write      (io, completed, &op)
		case Op_Next_Tick:   do_next_tick  (io, completed, &op)
		case Op_Poll:        do_poll       (io, completed, &op)
		case Op_Remove,
		     Op_Timeout:     unreachable()
		case:                unreachable()
		}
	}

	return nil
}

time_out_op :: proc(io: ^IO, completed: ^Completion) {
	context = completed.ctx
	switch &op in completed.operation {
	case Op_Accept:      op.callback(completed.user_data, {}, {}, .Timeout)
	case Op_Close:       op.callback(completed.user_data, .Timeout)
	case Op_Connect:     op.callback(completed.user_data, {}, net.Dial_Error.Timeout)
	case Op_Read:        op.callback(completed.user_data, 0, .Timeout)
	case Op_Recv:
		switch cb in op.callback {
		case On_Recv_TCP: cb(completed.user_data, 0, .Timeout)
		case On_Recv_UDP: cb(completed.user_data, 0, {}, .Timeout)
		case:             unreachable()
		}
	case Op_Send:
		switch cb in op.callback {
		case On_Sent_TCP: cb(completed.user_data, 0, .Timeout)
		case On_Sent_UDP: cb(completed.user_data, 0, .Timeout)
		case:             unreachable()
		}
	case Op_Write:       op.callback(completed.user_data, 0, .Timeout)
	case Op_Poll:        op.callback(completed.user_data, .Timeout)
	case Op_Timeout, Op_Next_Tick, Op_Remove: panic("timed out untimeoutable")
	case: unreachable()
	}
}

flush_io :: proc(io: ^IO, events: []kq.KEvent) -> (changed_events: int, completions: int) {
	events := events
	j: int
	events_loop: for i := 0; i < len(events); i += 1 {
		defer j += 1
		event := &events[i]
		if len(io.io_pending) <= j { return i, j }
		completion := io.io_pending[j]

		if completion.timeout == (^Completion)(TIMED_OUT) {
			time_out_op(io, completion)
			pool_put(&io.completion_pool, completion)
			i -= 1
			continue
		} else if completion.timeout == (^Completion)(REMOVED) {
			pool_put(&io.completion_pool, completion)
			i -= 1
			continue
        }

		completion.in_kernel = true

		switch op in completion.operation {
		case Op_Accept:
			event.ident = uintptr(op.sock)
			event.filter = .Read
		case Op_Connect:
			event.ident = uintptr(op.socket)
			event.filter = .Write
		case Op_Read:
			event.ident = uintptr(op.fd)
			event.filter = .Read
		case Op_Write:
			event.ident = uintptr(op.fd)
			event.filter = .Write
		case Op_Recv:
			event.ident = uintptr(net.any_socket_to_socket(op.socket))
			event.filter = .Read
		case Op_Send:
			event.ident = uintptr(net.any_socket_to_socket(op.socket))
			event.filter = .Write
		case Op_Poll:
			event.ident = uintptr(op.fd)
			switch op.event {
			case .Read:  event.filter = .Read
			case .Write: event.filter = .Write
			case:        unreachable()
			}

			event.flags = { .Add, .Enable }
			if !op.multi {
				event.flags += { .One_Shot }
			}

			event.udata = completion

			continue events_loop
		case Op_Remove:
			#partial switch inner_op in op.target.operation {
			case Op_Accept:
				event.ident = uintptr(inner_op.sock)
				event.filter = .Read
			case Op_Connect:
				event.ident = uintptr(inner_op.socket)
				event.filter = .Write
			case Op_Read:
				event.ident = uintptr(inner_op.fd)
				event.filter = .Read
			case Op_Write:
				event.ident = uintptr(inner_op.fd)
				event.filter = .Write
			case Op_Recv:
				event.ident = uintptr(net.any_socket_to_socket(inner_op.socket))
				event.filter = .Read
			case Op_Send:
				event.ident = uintptr(net.any_socket_to_socket(inner_op.socket))
				event.filter = .Write
			case Op_Poll:
				event.ident = uintptr(inner_op.fd)
				switch inner_op.event {
				case .Read:  event.filter = .Read
				case .Write: event.filter = .Write
				case:        unreachable()
				}
			case: panic("can not remove op")
			}

			event.flags = { .Delete, .Disable, .One_Shot }

			pool_put(&io.completion_pool, completion)
			pool_put(&io.completion_pool, op.target)
			continue events_loop

		case Op_Timeout, Op_Close, Op_Next_Tick:
			panic("invalid completion operation queued")
		}

		event.flags = { .Add, .Enable, .One_Shot }
		event.udata = completion
	}

	return len(events), j
}

flush_timeouts :: proc(io: ^IO) -> (min_timeout: Maybe(i64)) {
	io.now = time.now()

	for i := len(io.timeouts) - 1; i >= 0; i -= 1 {
		completion := io.timeouts[i]

		timeout, ok := &completion.operation.(Op_Timeout)
		if !ok { panic("non-timeout operation found in the timeouts queue") }

		unow := time.to_unix_nanoseconds(io.now)
		expires := time.to_unix_nanoseconds(timeout.expires)
		if unow >= expires {
			ordered_remove(&io.timeouts, i)

			if completion.timeout == (^Completion)(REMOVED) {
				pool_put(&io.completion_pool, completion)
				continue
			}

			do_timeout(io, completion, timeout)
			continue
		}

		timeout_ns := expires - unow
		if min, has_min_timeout := min_timeout.(i64); has_min_timeout {
			if timeout_ns < min {
				min_timeout = timeout_ns
			}
		} else {
			min_timeout = timeout_ns
		}
	}

	return
}

maybe_cancel_timeout :: #force_inline proc(completion: ^Completion) {
	if completion.timeout != nil {
		timeout := &completion.timeout.operation.(Op_Timeout)
		timeout.expires = { _nsec = -1 }
	}
}

do_accept :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	client, source, acc_err := net.accept_tcp(op.sock)
	if acc_err == .Would_Block {
		push_pending(io, completion)
		return
	}

	if acc_err == nil {
		if prep_err := _prepare_socket(client); prep_err != nil {
			net.close(client)
			acc_err = .Unknown
		}
	}

	if acc_err != nil {
		op.callback(completion.user_data, {}, {}, acc_err)
	} else {
		op.callback(completion.user_data, client, source, nil)
	}

	pool_put(&io.completion_pool, completion)
}

do_close :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	res := posix.close(op.handle)
	op.callback(completion.user_data, FS_Error(posix.errno()) if res != .OK else nil)
	pool_put(&io.completion_pool, completion)
}

do_connect :: proc(io: ^IO, completion: ^Completion, op: ^Op_Connect) {
	err: posix.Errno
	if op.initiated {
		// We have already called connect, retrieve error number only.
		size := posix.socklen_t(size_of(err))
		posix.getsockopt(posix.FD(op.socket), posix.SOL_SOCKET, .ERROR, &err, &size)
	} else {
		res := posix.connect(posix.FD(op.socket), (^posix.sockaddr)(&op.sockaddr), posix.socklen_t(op.sockaddr.ss_len))
		if res != .OK {
			err = posix.errno()
			if err == .EINPROGRESS {
				op.initiated = true
				push_pending(io, completion)
				return
			}
		}
	}

	if err != nil {
		net.close(op.socket)
		op.callback(completion.user_data, {}, _dial_error(err))
	} else {
		op.callback(completion.user_data, op.socket, nil)
	}

	pool_put(&io.completion_pool, completion)
}

do_read :: proc(io: ^IO, completion: ^Completion, op: ^Op_Read) {
	read := posix.pread(op.fd, raw_data(op.buf), len(op.buf), posix.off_t(op.offset)) // TODO: MAX_RW?
	if read < 0 {
		err := posix.errno()
		if err == .EWOULDBLOCK {
			push_pending(io, completion)
			return
		}

		op.callback(completion.user_data, op.read, FS_Error(err))
		pool_put(&io.completion_pool, completion)
		return
	}

	op.read += read

	if op.all && read > 0 && op.read < op.len {
		op.buf = op.buf[read:]
		op.offset += read

		do_read(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.read, nil)
	pool_put(&io.completion_pool, completion)
}

do_recv :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv) {
	switch sock in op.socket {
	case net.TCP_Socket:
		received, err := net.recv_tcp(sock, op.buf[:min(len(op.buf), MAX_RW)])
		if err != nil {
			if err == .Would_Block {
				push_pending(io, completion)
				return
			}

			maybe_cancel_timeout(completion)
			op.callback.(On_Recv_TCP)(completion.user_data, op.received, err)
			pool_put(&io.completion_pool, completion)
			return
		}

		op.received += received

		if op.all && received > 0 && op.received < op.len {
			op.buf = op.buf[received:]
			do_recv(io, completion, op)
			return
		}

		maybe_cancel_timeout(completion)
		op.callback.(On_Recv_TCP)(completion.user_data, op.received, nil)
		pool_put(&io.completion_pool, completion)

	case net.UDP_Socket:
		received, remote_endpoint, err := net.recv_udp(sock, op.buf[:min(len(op.buf), MAX_RW)])
		if err != nil {
			if err == .Would_Block {
				push_pending(io, completion)
				return
			}

			maybe_cancel_timeout(completion)
			op.callback.(On_Recv_UDP)(completion.user_data, op.received, remote_endpoint, err)
			pool_put(&io.completion_pool, completion)
			return
		}

		op.received += received

		if op.all && received > 0 && op.received < op.len {
			op.buf = op.buf[received:]
			do_recv(io, completion, op)
			return
		}

		maybe_cancel_timeout(completion)
		op.callback.(On_Recv_UDP)(completion.user_data, op.received, remote_endpoint, nil)
		pool_put(&io.completion_pool, completion)
	}
}

do_send :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	switch sock in op.socket {
	case net.TCP_Socket:
		sent := posix.send(posix.FD(sock), raw_data(op.buf), len(op.buf), {.NOSIGNAL}) // TODO: MAX_RW?
		if sent < 0 {
			err := _tcp_send_error()
			if err == .Would_Block {
				push_pending(io, completion)
				return
			}

			op.callback.(On_Sent_TCP)(completion.user_data, op.sent, err)
			pool_put(&io.completion_pool, completion)
			return
		}

		op.sent += sent

		if op.all && op.sent < op.len {
			op.buf = op.buf[sent:]
			do_send(io, completion, op)
			return
		}

		op.callback.(On_Sent_TCP)(completion.user_data, op.sent, nil)
		pool_put(&io.completion_pool, completion)

	case net.UDP_Socket:
		toaddr := _endpoint_to_sockaddr(op.endpoint.(net.Endpoint))
		sent := posix.sendto(posix.FD(sock), raw_data(op.buf), len(op.buf), {.NOSIGNAL}, (^posix.sockaddr)(&toaddr), posix.socklen_t(toaddr.ss_len)) // TODO: MAX_RW?
		if sent < 0 {
			err := _udp_send_error()
			if err == .Would_Block {
				push_pending(io, completion)
				return
			}

			op.callback.(On_Sent_UDP)(completion.user_data, op.sent, err)
			pool_put(&io.completion_pool, completion)
			return
		}

		op.sent += sent

		if op.all && op.sent < op.len {
			op.buf = op.buf[sent:]
			do_send(io, completion, op)
			return
		}

		op.callback.(On_Sent_UDP)(completion.user_data, op.sent, nil)
		pool_put(&io.completion_pool, completion)
	}
}

do_write :: proc(io: ^IO, completion: ^Completion, op: ^Op_Write) {
	written := posix.pwrite(op.fd, raw_data(op.buf), len(op.buf), posix.off_t(op.offset)) // TODO: MAX_RW?
	if written < 0 {
		err := posix.errno()
		if err == .EWOULDBLOCK {
			push_pending(io, completion)
			return
		}

		op.callback(completion.user_data, op.written, FS_Error(err))
		pool_put(&io.completion_pool, completion)
		return
	}

	op.written += written

	// The write did not write the whole buffer, need to write more.
	if op.all && op.written < op.len {
		op.buf = op.buf[written:]
		op.offset += written

		do_write(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.written, nil)
	pool_put(&io.completion_pool, completion)
}

do_timeout :: proc(io: ^IO, completion: ^Completion, op: ^Op_Timeout) {
	if rawptr(op.callback) == INTERNAL_TIMEOUT {
		// Timeout has been cancelled by a completed op.
		if op.expires == { _nsec = -1 } {
			pool_put(&io.completion_pool, completion)
			return
		}

		timed_out := (^Completion)(completion.user_data)

		// Timeout while the op is in the kernel, need to add a remove event to clean it out.
		if timed_out.in_kernel {
			completion.operation = Op_Remove {
				target = timed_out,
			}
			append(&io.io_pending, completion)
			time_out_op(io, timed_out)
			return
		}

		// Timeout while the op is in a queue to go into the kernel, avoid this by setting
		// a special timed out value that gets checked before an op goes to kernel.
		timed_out.timeout = (^Completion)(TIMED_OUT)
		pool_put(&io.completion_pool, completion)
		return
	}

	op.callback(completion.user_data)
	pool_put(&io.completion_pool, completion)
}

do_poll :: proc(io: ^IO, completion: ^Completion, op: ^Op_Poll) {
	op.callback(completion.user_data, .Ready) // TODO: Check error from the kqueue event.
	if !op.multi {
		pool_put(&io.completion_pool, completion)
	}
}

do_next_tick :: proc(io: ^IO, completion: ^Completion, op: ^Op_Next_Tick) {
	op.callback(completion.user_data)
	pool_put(&io.completion_pool, completion)
}

// Private proc in net package, verbatim copy.
_endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: posix.sockaddr_storage) {
	switch a in ep.address {
	case net.IP4_Address:
		(^posix.sockaddr_in)(&sockaddr)^ = posix.sockaddr_in {
			sin_port   = u16be(ep.port),
			sin_addr   = transmute(posix.in_addr)a,
			sin_family = .INET,
			sin_len    = size_of(posix.sockaddr_in),
		}
		return
	case net.IP6_Address:
		(^posix.sockaddr_in6)(&sockaddr)^ = posix.sockaddr_in6 {
			sin6_port   = u16be(ep.port),
			sin6_addr   = transmute(posix.in6_addr)a,
			sin6_family = .INET6,
			sin6_len    = size_of(posix.sockaddr_in6),
		}
		return
	}
	unreachable()
}
