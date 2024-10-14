#+build darwin, openbsd, netbsd, freebsd
#+private
package nbio

import    "base:runtime"

import    "core:container/queue"
import    "core:net"
import    "core:sys/posix"
import    "core:time"
import kq "core:sys/kqueue"

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
	operation: Operation,
	timeout:   ^Completion,
	in_kernel: bool,
	ctx:       runtime.Context,
}

Op_Accept :: struct {
	callback: On_Accept,
	sock:     net.TCP_Socket,
}

Op_Close :: struct {
	callback: On_Close,
	handle:   Handle,
}

Op_Connect :: struct {
	callback:  On_Connect,
	socket:    net.TCP_Socket,
	sockaddr:  posix.sockaddr_storage,
	initiated: bool,
}

Op_Recv :: struct {
	callback: On_Recv,
	socket:   net.Any_Socket,
	buf:      []byte,
	all:      bool,
	received: int,
	len:      int,
}

Op_Send :: struct {
	callback: On_Sent,
	socket:   net.Any_Socket,
	buf:      []byte,
	endpoint: Maybe(net.Endpoint),
	all:      bool,
	len:      int,
	sent:     int,
}

Op_Read :: struct {
	callback: On_Read,
	fd:       Handle,
	buf:      []byte,
	offset:	  int,
	all:   	  bool,
	read:  	  int,
	len:   	  int,
}

Op_Write :: struct {
	callback: On_Write,
	fd:       Handle,
	buf:      []byte,
	offset:   int,
	all:      bool,
	written:  int,
	len:      int,
}

Op_Timeout :: struct {
	callback: On_Timeout,
	expires:  time.Time,
}

Op_Next_Tick :: struct {
	callback: On_Next_Tick,
}

Op_Poll :: struct {
	callback: On_Poll,
	fd:       Handle,
	event:    Poll_Event,
	multi:    bool,
}

Op_Remove :: struct {
	target: ^Completion,
}

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

		max_timeout := time.Millisecond * 10
		timeout: posix.timespec
		timeout.tv_nsec = min(min_timeout.? or_else i64(max_timeout), i64(max_timeout))
		new_events: i32
		for {
			err: posix.Errno
			new_events, err = kq.kevent(io.kq, events[:change_events], events[:], &timeout)
			if err == .EINTR {
				assert(new_events == 0)
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

		if new_events > 0 {
			queue.reserve(&io.completed, int(new_events))
			for event in events[:new_events] {
				completion := cast(^Completion)event.udata
				completion.in_kernel = false
				push_completed(io, completion)
			}
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
        }

		assert(completed.timeout != (^Completion)(TIMED_OUT))

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
	case Op_Accept:      op.callback(completed.user_data, {}, {}, net.Accept_Error.Would_Block)
	case Op_Close:       op.callback(completed.user_data, .Timeout)
	case Op_Connect:     op.callback(completed.user_data, {}, net.Dial_Error.Timeout)
	case Op_Read:        op.callback(completed.user_data, 0, .Timeout)
	case Op_Recv:
		switch cb in op.callback {
		case On_Recv_TCP: cb(completed.user_data, 0, net.TCP_Recv_Error.Timeout)
		case On_Recv_UDP: cb(completed.user_data, 0, {}, net.UDP_Recv_Error.Timeout)
		case:             unreachable()
		}
	case Op_Send:
		switch cb in op.callback {
		case On_Sent_TCP: cb(completed.user_data, 0, net.TCP_Send_Error.Timeout)
		case On_Sent_UDP: cb(completed.user_data, 0, net.UDP_Send_Error.Timeout)
		case:             unreachable()
		}
	case Op_Write:       op.callback(completed.user_data, 0, .Timeout)
	case Op_Poll:        op.callback(completed.user_data, nil) // TODO: add error to callback
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

do_accept :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	client, source, err := net.accept_tcp(op.sock)
	if err == net.Accept_Error.Would_Block {
		push_pending(io, completion)
		return
	}

	if err == nil {
		err = _prepare_socket(client)
	}

	if err != nil {
		net.close(client)
		op.callback(completion.user_data, {}, {}, err.(net.Accept_Error))
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
	defer op.initiated = true

	err: posix.Errno
	if op.initiated {
		// We have already called os.connect, retrieve error number only.
		size := posix.socklen_t(size_of(err))
		posix.getsockopt(posix.FD(op.socket), posix.SOL_SOCKET, .ERROR, &err, &size)
	} else {
		res := posix.connect(posix.FD(op.socket), (^posix.sockaddr)(&op.sockaddr), posix.socklen_t(op.sockaddr.ss_len))
		if res != .OK {
			err = posix.errno()
			if err == .EINPROGRESS {
				push_pending(io, completion)
				return
			}
		}
	}

	if err != nil {
		net.close(op.socket)
		op.callback(completion.user_data, {}, net.Dial_Error(err))
	} else {
		op.callback(completion.user_data, op.socket, nil)
	}

	pool_put(&io.completion_pool, completion)
}

do_read :: proc(io: ^IO, completion: ^Completion, op: ^Op_Read) {
	read := posix.pread(op.fd, raw_data(op.buf), len(op.buf), posix.off_t(op.offset))
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

	if op.all && op.read < op.len {
		op.buf = op.buf[read:]
		op.offset += read

		do_read(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.read, nil)
	pool_put(&io.completion_pool, completion)
}

do_recv :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv) {
	// received: int
	// err: net.Network_Error
	// remote_endpoint: Maybe(net.Endpoint)
	switch sock in op.socket {
	case net.TCP_Socket:
		received, err := net.recv_tcp(sock, op.buf)
		if err != nil {
			// NOTE: Timeout is the name for EWOULDBLOCK in net package.
			if err == net.TCP_Recv_Error.Timeout {
				push_pending(io, completion)
				return
			}

			maybe_cancel_timeout(completion)
			op.callback.(On_Recv_TCP)(completion.user_data, op.received, err.(net.TCP_Recv_Error))
			pool_put(&io.completion_pool, completion)
			return
		}

		op.received += received

		if op.all && op.received < op.len {
			op.buf = op.buf[received:]
			do_recv(io, completion, op)
			return
		}

		maybe_cancel_timeout(completion)
		op.callback.(On_Recv_TCP)(completion.user_data, op.received, nil)
		pool_put(&io.completion_pool, completion)

	case net.UDP_Socket:
		received, remote_endpoint, err := net.recv_udp(sock, op.buf)
		if err != nil {
			// NOTE: Timeout is the name for EWOULDBLOCK in net package.
			if err == net.UDP_Recv_Error.Timeout {
				push_pending(io, completion)
				return
			}

			maybe_cancel_timeout(completion)
			op.callback.(On_Recv_UDP)(completion.user_data, op.received, remote_endpoint, err.(net.UDP_Recv_Error))
			pool_put(&io.completion_pool, completion)
			return
		}

		op.received += received

		if op.all && op.received < op.len {
			op.buf = op.buf[received:]
			do_recv(io, completion, op)
			return
		}

		maybe_cancel_timeout(completion)
		op.callback.(On_Recv_UDP)(completion.user_data, op.received, remote_endpoint, nil)
		pool_put(&io.completion_pool, completion)
	}
}

maybe_cancel_timeout :: #force_inline proc(completion: ^Completion) {
	if completion.timeout != nil {
		timeout := &completion.timeout.operation.(Op_Timeout)
		timeout.expires = { _nsec = -1 }
	}
}

do_send :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	switch sock in op.socket {
	case net.TCP_Socket:
		sent := posix.send(posix.FD(sock), raw_data(op.buf), len(op.buf), {.NOSIGNAL})
		if sent < 0 {
			errno := posix.errno()
			err   := net.TCP_Send_Error(errno)
			if errno == .EPIPE {
				err = net.TCP_Send_Error.Connection_Closed
			} else if errno == .EWOULDBLOCK {
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
		sent := posix.sendto(posix.FD(sock), raw_data(op.buf), len(op.buf), {.NOSIGNAL}, (^posix.sockaddr)(&toaddr), posix.socklen_t(toaddr.ss_len))
		if sent < 0 {
			errno := posix.errno()
			err   := net.UDP_Send_Error(errno)
			if errno == .EPIPE {
				err = net.UDP_Send_Error.Not_Socket
			} else if errno == .EWOULDBLOCK {
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
	written := posix.pwrite(op.fd, raw_data(op.buf), len(op.buf), posix.off_t(op.offset))
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
	op.callback(completion.user_data, op.event)
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
