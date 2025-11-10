#+private file
package nbio

import "core:container/queue"
import "core:nbio/uring"
import "core:container/pool"
import "core:net"
import "core:sys/linux"
import "core:time"
import "core:mem"
import "core:log"

QUEUE_SIZE :: 1024
#assert(QUEUE_SIZE <= uring.MAX_ENTRIES)
#assert(size_of(linux.IO_Uring_CQE) * QUEUE_SIZE < 1024 * 512) // Smaller than .5 MB, maybe should be even smaller (we have a stack buffer), could put it on the heap too.

// NOTE: link_timeout is not enqueued again after a callback requeues because of EINTR or EWOULDBLOCK.
// NOTE: made those a panic now, see if it's even hit?

// TODO: double check timeouts, do we want them to be absolute from the time they are submitted?

// TODO: recv, send, write, read with [][]byte

// TODO: make sure io.ring.features has all the features we use.

// TODO: double check order and use of the submission/copy_completions in the tick, can prob be better.
// see if we need to call uring.submit/need to enter kernel.
// It may be better to do flush_completions giving it we want 1 completion, or a timeout.
// submit seems to be something you need with specific flags.

// TODO: arbitrarily long paths in open().

// TODO: POLL: make sure that if multi was set, that the IORING_CQE_F_MORE flag is not set which
// means we won't get any more events.

// TODO: multi variant of accept

// TODO: multi variant of timeout

@(private="package")
_Event_Loop :: struct {
	ring:            uring.Ring,
	// Ready to be submitted to kernel, if kernel is full.
	unqueued:        queue.Queue(^Operation),
	// Ready to run callbacks, mainly next tick, some other ops that error outside the kernel.
	completed:       queue.Queue(^Operation),
	ios_queued:      u64,
	ios_in_kernel:   u64,
	allocator:       mem.Allocator,
}

@(private="package")
_Handle :: linux.Fd

@(private="package")
_Operation :: struct {
	result:    i32,
	removal:   ^Operation,
	sqe:       ^linux.IO_Uring_SQE,
}

@(private="package")
_Accept :: struct {
	sockaddr:     linux.Sock_Addr_Any,
	sockaddr_len: i32,
}

@(private="package")
_Close :: struct {}

@(private="package")
_Dial :: struct {
	sockaddr: linux.Sock_Addr_Any,
}

@(private="package")
_Read :: struct {}

@(private="package")
_Write :: struct {}

@(private="package")
_Send :: struct {
	endpoint: linux.Sock_Addr_Any,
}

@(private="package")
_Recv :: struct {
	addr_out:    linux.Sock_Addr_Any,
	iov_backing: [1]linux.IO_Vec,
	msghdr:      linux.Msg_Hdr,
}

@(private="package")
_Timeout :: struct {
	expires: linux.Time_Spec,
}

@(private="package")
_Poll :: struct {}

@(private="package")
_Remove :: struct {
	target: ^Operation,
}

@(private="package")
_Link_Timeout :: struct {
	target:  ^Operation,
	expires: linux.Time_Spec,
}

@(private="package")
_Send_File :: struct {
	splice: ^Operation,
	len:    int,
	pipe:   Handle,
}

@(private="package")
_Splice :: struct {
	len:     int,
	file:    Handle,
	pipe:    Handle,

	written: int,
}

@(private="package")
_init :: proc(l: ^Event_Loop, alloc: mem.Allocator) -> (err: General_Error) {
	params := uring.DEFAULT_PARAMS
	params.flags += {.SUBMIT_ALL, .COOP_TASKRUN, .SINGLE_ISSUER}

	uerr := uring.init(&l.ring, &params, QUEUE_SIZE)
	if uerr != nil {
		err = General_Error(uerr)
		return
	}
	defer if err != nil { uring.destroy(&l.ring) }

	if perr := queue.init(&l.unqueued, allocator = alloc); perr != nil {
		err = .Allocation_Failed
		return
	}
	defer if err != nil { queue.destroy(&l.unqueued) }

	if perr := queue.init(&l.completed, allocator = alloc); perr != nil {
		err = .Allocation_Failed
		return
	}

	return
}

@(private="package")
_destroy :: proc(l: ^Event_Loop) {
	queue.destroy(&l.unqueued)
	queue.destroy(&l.completed)
	uring.destroy(&l.ring)
}

@(private="package")
__tick :: proc(l: ^Event_Loop) -> General_Error {

	_flush_completions :: proc(l: ^Event_Loop, wait: bool) -> linux.Errno {
		wait := wait
		cqes: [QUEUE_SIZE]linux.IO_Uring_CQE = ---
		for {
			completed := uring.copy_cqes(&l.ring, cqes[:], 1 if wait else 0) or_return
			wait = false
			l.ios_in_kernel -= u64(completed)

			completed_loop: for cqe in cqes[:completed] {
				assert(cqe.user_data != 0)
				completed := cast(^Operation)uintptr(cqe.user_data)

				if completed._impl.removal != nil {
					pool.put(&l.operation_pool, completed)
					continue
				}

				completed._impl.result = cqe.res
				context = completed.ctx

				switch completed.type {
				case .Accept:        _accept_callback(completed)
				case .Dial:          _dial_callback(completed)
				case .Timeout:       _timeout_callback(completed)
				case .Write:         _write_callback(completed) or_continue completed_loop
				case .Read:          _read_callback(completed) or_continue completed_loop
				case .Close:         _close_callback(completed)
				case .Poll:          _poll_callback(completed) or_continue completed_loop
				case .Send:          _send_callback(completed) or_continue completed_loop
				case .Recv:          _recv_callback(completed) or_continue completed_loop
				case .Send_File:     _sendfile_callback(completed) or_continue completed_loop
				case ._Splice:
					if _splice_callback(completed) {
						pool.put(&l.operation_pool, completed)
					}
					continue completed_loop
				case ._Remove:       // no-op
				case ._Link_Timeout: // no-op
				case:                panic("corrupted operation")
				}

				completed.cb(completed)
				pool.put(&l.operation_pool, completed)
			}

			if completed < len(cqes) { break }
			log.debug("copy_cqes filled up entire buffer, shouldn't be possible because it's the size of the queue?")
		}

		return nil
	}

	_flush_submissions :: proc(l: ^Event_Loop) -> linux.Errno {
		for {
			ts: linux.Time_Spec
			ts.time_nsec = uint(IDLE_TIME)
			submitted, err := uring.submit(&l.ring, 1, &ts)
			#partial switch err {
			case .NONE, .ETIME:
			case .EINTR:
				continue
			case .ENOMEM:
				// It's full, wait for at least one operation to complete and try again.
				log.debug("could not flush submissions, ENOMEM, waiting for operations to complete before continuing")
				ferr := _flush_completions(l, true)
				if ferr != nil { return ferr }
				continue
			case:
				return err
			}

			l.ios_queued    -= u64(submitted)
			l.ios_in_kernel += u64(submitted)
			break
		}

		return nil
	}

	err := _flush_submissions(l)
	if err != nil { return General_Error(err) }

	l.now = time.now()

	// Execute completed operations, mostly next tick ops, also some other ops that may error before
	// adding it to the Uring.
	n := queue.len(l.completed)
	for _ in 0 ..< n {
		completed := queue.pop_front(&l.completed)
		context = completed.ctx
		completed.cb(completed)
		pool.put(&l.operation_pool, completed)
	}

	err = _flush_completions(l, false)
	if err != nil { return General_Error(err) }

	// Store length at this time, so we don't infinite loop if any of the enqueue
	// procs below then add to the queue again.
	n = queue.len(l.unqueued)
	for _ in 0..<n {
		unqueued := queue.pop_front(&l.unqueued)

		if unqueued._impl.removal != nil {
			_remove_callback(unqueued._impl.removal)
			continue
		}

		_exec(unqueued)

		if unqueued._impl.sqe == nil && queue.len(l.unqueued) > 0 {
			log.debug("trying to enqueue unqueued but still not able to")

			// Kind of hacky way to keep the link intact, so we do not requeue the linked op without requeuing the link too.
			front := queue.peek_front(&l.unqueued)
			if front^.type == ._Link_Timeout {
				queue.push_back(&l.unqueued, queue.pop_front(&l.unqueued))
			}

			break
		}
	}

	return nil
}

@(private="package")
_exec :: proc(op: ^Operation) {
	assert(op.l == &_tls_event_loop)
	switch op.type {
	case .Accept:        _accept_exec(op)
	case .Dial:          _dial_exec(op)
	case .Read:          _read_exec(op)
	case .Write:         _write_exec(op)
	case .Recv:          _recv_exec(op)
	case .Send:          _send_exec(op)
	case .Poll:          _poll_exec(op)
	case .Close:         _close_exec(op)
	case .Timeout:       _timeout_exec(op)
	case .Send_File:     _sendfile_exec(op)
	case ._Splice:       unreachable()
	case ._Remove:       unreachable()
	case ._Link_Timeout: unreachable()
	case:                panic("corrupted operation type")
	}
}

@(private="package")
_open :: proc(l: ^Event_Loop, path: string, flags: File_Flags, perm: int) -> (handle: Handle, err: FS_Error) {
	if path == "" {
		err = .Invalid_Argument
		return
	}

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

@(private="package")
_listen :: proc(socket: TCP_Socket, backlog := 1000) -> net.Listen_Error {
	err := linux.listen(linux.Fd(socket), i32(backlog))
	if err != nil {
		return net._listen_error(err)
	}
	return nil
}

@(private="package")
_remove :: proc(target: ^Operation) {
	target := target
	assert(target != nil)

	op := _prep(target.l, _remove_callback, ._Remove)
	op._remove.target = target

	target._impl.removal = op

	_enqueue(op, uring.async_cancel(
		&op.l.ring,
		u64(uintptr(target)),
		u64(uintptr(op)),
	))
}

_enqueue :: proc(op: ^Operation, sqe: ^linux.IO_Uring_SQE, ok: bool) {
	if !ok {
		log.debug("queueing operation because the IO Uring is full")
		pok, _ := queue.push_back(&op.l.unqueued, op)
		if !pok {
			panic("nbio unqueued queue allocation failure")
		}
		return
	}

	op._impl.sqe = sqe
	op.l.ios_queued += 1	
}

_link_timeout :: proc(target: ^Operation, timeout: time.Duration) {
	if timeout <= 0 {
		return
	}

	op := _prep(target.l, _link_timeout_callback, ._Link_Timeout)
	op._link_timeout.target = target
	op._link_timeout.expires = _duration_to_time_spec(timeout)

	// If the last op was queued because kernel is full, also queue this op.
	if queue.len(target.l.unqueued) > 0 && queue.peek_back(&target.l.unqueued)^ == target {
		_enqueue(op, nil, false)
		return
	}

	assert(op._link_timeout.target._impl.sqe != nil)
	op._link_timeout.target._impl.sqe.flags += {.IO_LINK}

	sqe, ok := uring.link_timeout(
		&target.l.ring,
		u64(uintptr(op)),
		&op._link_timeout.expires,
		{},
	)
	// If the target wasn't queued, the link timeout should not need to be queued, because uring
	// leaves one spot specifically for a link_timeout.
	assert(ok)

	_enqueue(op, sqe, ok)
}

_remove_callback :: proc(op: ^Operation) {
	assert(op.type == ._Remove)
	err := linux.Errno(-op._impl.result)
	if err != nil && err != .ENOENT {
		panic("unexpected nbio.remove() error")
	}
}

_accept_exec :: proc(op: ^Operation) {
	assert(op.type == .Accept)
	op.accept._impl.sockaddr_len = size_of(op.accept._impl.sockaddr)
	_enqueue(op, uring.accept(
		&op.l.ring,
		u64(uintptr(op)),
		linux.Fd(op.accept.socket),
		&op.accept._impl.sockaddr,
		&op.accept._impl.sockaddr_len,
		{},
	))
	_link_timeout(op, op.accept.timeout)
}

_accept_callback :: proc(op: ^Operation) {
	assert(op.type == .Accept)
	if op._impl.result < 0 {
		errno := linux.Errno(-op._impl.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			log.panic("accept callback EINTR or EWOULDBLOCK, can this happen?")
			// accept_enqueue(io, completion, op)
			// return
		case .ECANCELED:
			op.accept.err = .Timeout
		case:
			op.accept.err = net._accept_error(errno)
		}

		return
	}

	op.accept.client = TCP_Socket(op._impl.result)
	net.set_blocking(net.TCP_Socket(op.accept.client), false)
	op.accept.client_endpoint = _sockaddr_storage_to_endpoint(&op.accept._impl.sockaddr)
}

_dial_exec :: proc(op: ^Operation) {
	assert(op.type == .Dial)
	if op.dial.socket == {} {
		if op.dial.endpoint.port == 0 {
			op.dial.err = .Port_Required
			queue.push_back(&op.l.completed, op)
			return
		}

		sock, err := create_socket(net.family_from_endpoint(op.dial.endpoint), .TCP)
		if err != nil {
			op.dial.err = err
			queue.push_back(&op.l.completed, op)
			return
		}
		defer if op.dial.err != nil { close(sock.(TCP_Socket)) }

		op.dial.socket = sock.(TCP_Socket)

		if err := net.set_blocking(sock, false); err != nil {
			op.dial.err = err
			queue.push_back(&op.l.completed, op)
			return
		}

		net.set_option(sock, .Reuse_Address, true)
	}

	_enqueue(op, uring.connect(
		&op.l.ring,
		u64(uintptr(op)),
		linux.Fd(op.dial.socket),
		&op.dial._impl.sockaddr,
	))
	_link_timeout(op, op.dial.timeout)
}

_dial_callback :: proc(op: ^Operation) {
	assert(op.type == .Dial)
	errno := linux.Errno(-op._impl.result)
	if errno != nil {
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			log.panic("connect callback EINTR or EWOULDBLOCK, can this happen?")
			// connect_enqueue(io, completion, op)
			// return
		case .ECANCELED:
			op.dial.err = net.Dial_Error.Timeout
		case:
			op.dial.err = net._dial_error(errno)
		}
		close(op.dial.socket)
	}
}

_timeout_exec :: proc(op: ^Operation) {
	assert(op.type == .Timeout)
	if op.timeout.duration == 0 {
		queue.push_back(&op.l.completed, op)
		return
	}

	op.timeout._impl.expires = _duration_to_time_spec(op.timeout.duration)
	_enqueue(op, uring.timeout(
		&op.l.ring,
		u64(uintptr(op)),
		&op.timeout._impl.expires,
		0,
		{},
	))
}

_timeout_callback :: proc(op: ^Operation) {
	if op._impl.result < 0 {
		errno := linux.Errno(-op._impl.result)
		#partial switch errno {
		case .ETIME, .ECANCELED: // OK.
		case .EINTR, .EWOULDBLOCK:
			log.panic("timeout callback EINTR or EWOULDBLOCK, can this happen?")
			// timeout_enqueue(io, completion, op)
			// return
		case:
			log.panic("timeout error")
		}
	}
}

_close_exec :: proc(op: ^Operation) {
	assert(op.type == .Close)

	fd: linux.Fd
	switch closable in op.close.subject {
	case Handle:     fd = linux.Fd(closable)
	case TCP_Socket: fd = linux.Fd(closable)
	case UDP_Socket: fd = linux.Fd(closable)
	case:            panic("corrupted closable")
	}

	_enqueue(op, uring.close(
		&op.l.ring,
		u64(uintptr(op)),
		fd,
	))
}

_close_callback :: proc(op: ^Operation) {
	assert(op.type == .Close)
	op.close.err = FS_Error(linux.Errno(-op._impl.result))
}

_recv_exec :: proc(op: ^Operation) {
	assert(op.type == .Recv)

	switch sock in op.recv.socket {
	case TCP_Socket:
		_enqueue(op, uring.recv(
			&op.l.ring,
			u64(uintptr(op)),
			linux.Fd(sock),
			op.recv.buf[op.recv.received:],
			{},
		))

	case UDP_Socket:
		// NOTE: no recvfrom?
		
		buf := op.recv.buf[op.recv.received:]
		op.recv._impl.iov_backing[0] = {raw_data(buf), len(buf)}

		op.recv._impl.msghdr = {
			name = &op.recv._impl.addr_out,
			namelen = size_of(op.recv._impl.addr_out),
			iov = op.recv._impl.iov_backing[:],
		}

		_enqueue(op, uring.recvmsg(
			&op.l.ring,
			u64(uintptr(op)),
			linux.Fd(sock),
			&op.recv._impl.msghdr,
			{},
		))

	case: panic("corrupted socket")
	}

	_link_timeout(op, op.recv.timeout)
}

@(require_results)
_recv_callback :: proc(op: ^Operation) -> bool {
	assert(op.type == .Recv)

	if op._impl.result < 0 {
		errno := linux.Errno(-op._impl.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			log.panic("recv callback EINTR or EWOULDBLOCK, can this happen?")
			// recv_enqueue(io, completion, op)
			// return
		}

		switch sock in op.recv.socket {
		case TCP_Socket:
			#partial switch errno {
			case .ECANCELED:
				op.recv.err = net.TCP_Recv_Error.Timeout
			case:
				op.recv.err = net._tcp_recv_error(errno)
			}
		case UDP_Socket:
			#partial switch errno {
			case .ECANCELED:
				op.recv.err = net.UDP_Recv_Error.Timeout
			case:
				op.recv.err = net._udp_recv_error(errno)
			}
		case:
			panic("corrupted socket")
		}

		return true
	}

	op.recv.received += int(op._impl.result)

	if op.recv.all && op._impl.result > 0 && op.recv.received < len(op.recv.buf) {
		_recv_exec(op)
		return false
	}

	op.recv.source = _sockaddr_storage_to_endpoint(&op.recv._impl.addr_out)
	return true
}

_send_exec :: proc(op: ^Operation) {
	assert(op.type == .Send)
	switch sock in op.send.socket {
	case TCP_Socket:
		_enqueue(op, uring.send(
			&op.l.ring,
			u64(uintptr(op)),
			linux.Fd(sock),
			op.send.buf[op.send.sent:],
			{.NOSIGNAL},
		))
	case UDP_Socket:
		op.send._impl.endpoint = _endpoint_to_sockaddr(op.send.endpoint)
		_enqueue(op, uring.sendto(
			&op.l.ring,
			u64(uintptr(op)),
			linux.Fd(sock),
			op.send.buf[op.send.sent:],
			{.NOSIGNAL},
			&op.send._impl.endpoint,
		))
	}
	_link_timeout(op, op.send.timeout)
}

@(require_results)
_send_callback :: proc(op: ^Operation) -> bool {
	assert(op.type == .Send)
	if op._impl.result < 0 {
		errno := linux.Errno(-op._impl.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			log.panic("send callback EINTR or EWOULDBLOCK, can this happen?")
			// send_enqueue(io, completion, op)
			// return
		}

		switch sock in op.send.socket {
		case TCP_Socket:
			#partial switch errno {
			case .ECANCELED:
				op.send.err = net.TCP_Send_Error.Timeout
			case:
				op.send.err = net._tcp_send_error(errno)
			}
		case UDP_Socket:
			#partial switch errno {
			case .ECANCELED:
				op.send.err = net.UDP_Send_Error.Timeout
			case:
				op.send.err = net._udp_send_error(errno)
			}
		case: panic("corrupted socket")
		}

		return true
	}

	op.send.sent += int(op._impl.result)

	if op.send.all && op._impl.result > 0 && op.send.sent < len(op.send.buf) {
		_send_exec(op)
		return false
	}

	return true
}

_write_exec :: proc(op: ^Operation) {
	_enqueue(op, uring.write(
		&op.l.ring,
		u64(uintptr(op)),
		op.write.fd,
		op.write.buf[op.write.written:],
		u64(op.write.offset) + u64(op.write.written),
	))
	_link_timeout(op, op.write.timeout)
}

@(require_results)
_write_callback :: proc(op: ^Operation) -> bool {
	if op._impl.result < 0 {
		errno := linux.Errno(-op._impl.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			log.panic("write callback EINTR or EWOULDBLOCK, can this happen?")
			// write_enqueue(io, completion, op)
		}

		op.write.err = FS_Error(errno)
		return true
	}

	op.write.written += int(op._impl.result)

	if op.write.all && op.write.written < len(op.write.buf) {
		_write_exec(op)
		return false
	}

	return true
}

_read_exec :: proc(op: ^Operation) {
	_enqueue(op, uring.read(
		&op.l.ring,
		u64(uintptr(op)),
		op.read.fd,
		op.read.buf[op.read.read:],
		u64(op.read.offset) + u64(op.read.read),
	))
	_link_timeout(op, op.read.timeout)
}

@(require_results)
_read_callback :: proc(op: ^Operation) -> bool {
	if op._impl.result < 0 {
		errno := linux.Errno(-op._impl.result)
		#partial switch errno {
		case .EINTR, .EWOULDBLOCK:
			log.panic("read callback EINTR or EWOULDBLOCK, can this happen?")
			// read_enqueue(io, completion, op)
		}

		op.read.err = FS_Error(errno)
		return true
	}

	op.read.read += int(op._impl.result)

	if op.read.all && op.read.read < len(op.read.buf) {
		_read_exec(op)
		return false
	}

	return true
}

_poll_exec :: proc(op: ^Operation) {
	events: linux.Fd_Poll_Events
	if .Read  in op.poll.events { events += { .IN } }
	if .Write in op.poll.events { events += { .OUT } }

	flags: linux.IO_Uring_Poll_Add_Flags
	if op.poll.multi {
		flags += { .ADD_MULTI }
	}

	fd: linux.Fd
	switch sock in op.poll.socket {
	case TCP_Socket: fd = linux.Fd(sock)
	case UDP_Socket: fd = linux.Fd(sock)
	}

	_enqueue(op, uring.poll_add(
		&op.l.ring,
		u64(uintptr(op)),
		fd,
		events,
		flags,
	))
	_link_timeout(op, op.poll.timeout)
}

@(require_results)
_poll_callback :: proc(op: ^Operation) -> bool {
	if op._impl.result < 0 {
		errno := linux.Errno(-op._impl.result)
		#partial switch errno {
		case .NONE: // no-op
		case .ECANCELED:
			op.poll.result = .Timeout
		case .EINTR, .EWOULDBLOCK:
			log.panic("poll callback EINTR or EWOULDBLOCK, can this happen?")
			// if !op.multi {
			// 	poll_enqueue(io, completion, op)
			// }
		case .EINVAL, .EFAULT, .EBADF:
			op.poll.result = .Invalid_Argument
		case:
			op.poll.result = .Error
		}

		return true
	}

	events := transmute(linux.Fd_Poll_Events)u16(op._impl.result)
	if .IN  in events { op.poll.result_events += { .Read } }
	if .OUT in events { op.poll.result_events += { .Write } }

	op.poll.result = .Ready

	if op.poll.multi {
		op.cb(op)
		return false
	}

	return true
}

_sendfile_exec :: proc(op: ^Operation) {
	assert(op.type == .Send_File)

	if op.sendfile._impl.splice == nil {
		rw: [2]linux.Fd
		err := linux.pipe2(&rw, {.NONBLOCK, .CLOEXEC})
		if err != nil {
			op.sendfile.err = FS_Error(err)
			queue.push_back(&op.l.completed, op)
			return
		}

		// TODO: take in a length and offset, don't stat here.

		stat: linux.Stat
		err = linux.fstat(op.sendfile.file, &stat)
		if err != nil {
			op.sendfile.err = FS_Error(err)
			queue.push_back(&op.l.completed, op)
			return
		}

		if !linux.S_ISREG(stat.mode) {
			op.sendfile.err = .Invalid_Argument
			queue.push_back(&op.l.completed, op)
			return
		}

		splice_op := _prep(op.l, nil, ._Splice)
		splice_op._splice.file = op.sendfile.file
		splice_op._splice.pipe = rw[1]
		splice_op._splice.len  = int(stat.size)  // TODO: could overflow
		_splice_exec(splice_op)

		op.sendfile._impl.splice = splice_op

		op.sendfile._impl.pipe = rw[0]
		op.sendfile._impl.len  = int(stat.size)
	}

	sockfd: linux.Fd
	switch sock in op.sendfile.socket {
	case TCP_Socket: sockfd = linux.Fd(sock)
	case UDP_Socket: sockfd = linux.Fd(sock)
	case:            panic("corrupted socket")
	}

	_enqueue(op, uring.splice(
		&op.l.ring,
		u64(uintptr(op)),
		op.sendfile._impl.pipe,
		-1,
		sockfd,
		-1,
		u32(op.sendfile._impl.len-op.sendfile.sent), // TODO: could overflow
		{.NONBLOCK},
	))

	// TODO: timeout should decrease when reentrant, is for the whole package btw.

	_link_timeout(op, op.sendfile.timeout)
}

_splice_exec :: proc(op: ^Operation) {
	assert(op.type == ._Splice)

	_enqueue(op, uring.splice(
		&op.l.ring,
		u64(uintptr(op)),
		op._splice.file,
		i64(op._splice.written),
		op._splice.pipe,
		-1,
		u32(op._splice.len-op._splice.written), // TODO: could overflow
		{.NONBLOCK},
	))

}

_splice_callback :: proc(op: ^Operation) -> bool {
	assert(op.type == ._Splice)

	if op._impl.result < 0 {
		errno := linux.Errno(-op._impl.result)
		#partial switch errno {
		case .EAGAIN:
			// NOTE: doesn't seem like io_uring is smart about splice and "automatically" only
			// completing if it's writable, so we have to poll.

			// NOTE: poll in the public facing API only accepts sockets because Windows can't do
			// polling on files, but linux can handle it just fine, so we can just cast it to a socket.

			poll_poly(TCP_Socket(op._splice.pipe), {.Write}, op, proc(poll_op: ^Operation, splice_op: ^Operation) {
				assert(poll_op.poll.result == .Ready) // TODO: handle errors.
				_splice_exec(splice_op)
			})

			return false
		case:
			linux.close(op._splice.pipe)

			// TODO: complete the parent sendfile with the error.
			// Cancel the rest.
			// return true

			log.panicf("splice error: %v %m/%m", errno, op._splice.written, op._splice.len)
		}
	}

	log.infof("spliced: %m", op._impl.result)

	op._splice.written += int(op._impl.result)
	if op._splice.written < op._splice.len {
		_splice_exec(op)
		return false
	}

	linux.close(op._splice.pipe)
	return true
}

_sendfile_callback :: proc(op: ^Operation) -> bool {
	assert(op.type == .Send_File)

	if op._impl.result < 0 {
		errno := linux.Errno(-op._impl.result)
		#partial switch errno {
		case .EAGAIN:
			log.debug("SEND EAGAIN")

			// NOTE: doesn't seem like io_uring is smart about splice and "automatically" only
			// completing if it's writable, so we have to poll.

			poll := poll_poly(op.sendfile.socket, {.Write}, op, proc(poll_op: ^Operation, sendfile_op: ^Operation) {
				assert(poll_op.poll.result == .Ready) // TODO: handle errors.
				_sendfile_exec(sendfile_op)
			})

			// TODO: timeout should decrease when reentrant, is for the whole package btw.
			_link_timeout(poll, op.sendfile.timeout)

			return false

		case .ECANCELED:
			op.sendfile.err = .Timeout
		case:
			op.sendfile.err = FS_Error(errno)
		}

		linux.close(op.sendfile._impl.pipe)
		return true
	}

	log.infof("sent: %m", op._impl.result)

	op.sendfile.sent += int(op._impl.result)
	if op.sendfile.sent < op.sendfile._impl.len {
		_sendfile_exec(op)
		return false
	}

	linux.close(op.sendfile._impl.pipe)
	return true
}

_link_timeout_callback :: proc(op: ^Operation) {
	err := linux.Errno(-op._impl.result)
	if err != nil && err != .ETIME && err != .ECANCELED {
		panic("unexpected nbio.link_timeout() error")
	}
}

@(require_results)
_sockaddr_storage_to_endpoint :: proc(addr: ^linux.Sock_Addr_Any) -> (ep: net.Endpoint) {
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
	case:
		return {}
	}
}

@(require_results)
_endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: linux.Sock_Addr_Any) {
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

@(require_results)
_duration_to_time_spec :: proc(duration: time.Duration) -> linux.Time_Spec {
	NANOSECONDS_PER_SECOND :: 1e9
	nsec := time.duration_nanoseconds(duration)
	return {
		time_sec  = uint(nsec / NANOSECONDS_PER_SECOND),
		time_nsec = uint(nsec % NANOSECONDS_PER_SECOND),
	}
}
