#+private
package nbio

import "base:runtime"

import "core:container/queue"
import "core:log"
import "core:mem"
import "core:net"
import "core:time"

import win "core:sys/windows"

// TODO: we may want one iocp per application, and each threads calls GetQueuedblahblah on it.
// Windows seems to have designed it for that use case.
// BUT! I don't think we can then guarantee that a socket is "owned" by a thread, like the other impls do, is that a problem?

_IO :: struct #no_copy {
	iocp:            win.HANDLE,
	allocator:       mem.Allocator,
	timeouts:        [dynamic]^Completion,
//	polls:           [dynamic]^Completion,
//	_polls:          [dynamic]win.WSA_POLLFD,
	polls:         	 #soa [dynamic]Poll,
	completed:       queue.Queue(^Completion),
	completion_pool: Pool,
	io_pending:      int,
}

Poll :: struct {
	fd: win.WSA_POLLFD,
	completion: ^Completion,
}

TIMED_OUT :: rawptr(max(uintptr))
REMOVED   :: rawptr(max(uintptr)-1)

_Completion :: struct {
	over:      win.OVERLAPPED,
	ctx:       runtime.Context,
	op:        Operation,
	timeout:   ^Completion,
	in_kernel: bool,
}
#assert(offset_of(Completion, over) == 0, "needs to be the first field to work")

_Handle :: distinct uintptr

INVALID_HANDLE :: Handle(win.INVALID_HANDLE)

MAX_RW :: mem.Gigabyte

Operation :: union {
	Op_Accept,
	Op_Close,
	Op_Connect,
	Op_Read,
	Op_Recv,
	Op_Send,
	Op_Write,
	Op_Timeout,
	Op_Next_Tick,
	Op_Poll,
	Op_Remove,
}

Op_Accept :: struct {
	callback: On_Accept,
	socket:   win.SOCKET,
	client:   win.SOCKET,
	addr:     win.SOCKADDR_STORAGE_LH,
	pending:  bool, // TODO: reuse in_kernel of the completion?
}

Op_Connect :: struct {
	callback: On_Dial,
	socket:   win.SOCKET,
	addr:     win.SOCKADDR_STORAGE_LH,
	pending:  bool, // TODO: reuse in_kernel of the completion?
}

Op_Close :: struct {
	callback: On_Close,
	fd:       Closable,
}

Op_Read :: struct {
	callback: On_Read,
	fd:       Handle,
	offset:   int,
	buf:      []byte,
	pending:  bool, // TODO: reuse in_kernel of the completion?
	all:      bool,
	read:     int,
	len:      int,
}

Op_Write :: struct {
	callback: On_Write,
	fd:       Handle,
	offset:   int,
	buf:      []byte,
	pending:  bool, // TODO: reuse in_kernel of the completion?

	written:  int,
	len:      int,
	all:      bool,
}

Op_Recv :: struct {
	callback: On_Recv,
	socket:   net.Any_Socket,
	buf:      win.WSABUF,
	pending:  bool, // TODO: reuse in_kernel of the completion?
	all:      bool,
	received: int,
	len:      int,
}

Op_Send :: struct {
	callback: On_Sent,
	socket:   net.Any_Socket,
	buf:      win.WSABUF,
	pending:  bool, // TODO: reuse in_kernel of the completion?

	len:      int,
	sent:     int,
	all:      bool,
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
	idx:      int,
	multi:    bool,
}

Op_Remove :: struct {}

flush_timeouts :: proc(io: ^IO) -> (expires: Maybe(time.Duration)) {
	curr: time.Time
	timeout_len := len(io.timeouts)

	// PERF: could use a faster clock, is getting time since program start fast?
	if timeout_len > 0 { curr = _now(io) }

	for i := 0; i < timeout_len; {
		completion := io.timeouts[i]
		op := &completion.op.(Op_Timeout)
		cexpires := time.diff(curr, op.expires)

		// Timeout done.
		if (cexpires <= 0 || completion.timeout == (^Completion)(REMOVED)) {
			ordered_remove(&io.timeouts, i) // TODO: ordered remove bad.
			queue.push_back(&io.completed, completion)
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

submit :: proc(io: ^IO, user: rawptr, op: Operation) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.op = op

	queue.push_back(&io.completed, completion)
	return completion
}

handle_completion :: proc(io: ^IO, completion: ^Completion) {
	// TODO: do we need to do anything if the completion is in the kernel? / does a CancelIoEx cause a final cancel signal on the iocp we need to catch?

	if !completion.in_kernel && completion.timeout != (^Completion)(REMOVED) {
		pool_put(&io.completion_pool, completion)
		return
	}

	completed: bool
	defer if !completed {
		completion.in_kernel = true
	}

	switch &op in completion.op {
	case Op_Accept:
		// TODO: we should directly call the accept callback here, no need for it to be on the Op_Acccept struct.
		source, err := accept_callback(io, completion, &op)
		if wsa_err_incomplete(err) {
			io.io_pending += 1
			return
		}

		if err != nil { win.closesocket(op.client) }

		op.callback(completion.user_data, net.TCP_Socket(op.client), source, err)

	case Op_Connect:
		err := connect_callback(io, completion, &op)
		if wsa_err_incomplete(err) {
			io.io_pending += 1
			return
		}

		if err != nil { win.closesocket(op.socket) }

		op.callback(completion.user_data, net.TCP_Socket(op.socket), err)

	case Op_Close:
		op.callback(completion.user_data, close_callback(io, op))

	case Op_Read:
		read, err := read_callback(io, completion, &op)
		if err_incomplete(err) {
			io.io_pending += 1
			return
		}

		if err == win.ERROR_HANDLE_EOF {
			err = win.NO_ERROR
		}

		op.read += int(read)

		if err != win.NO_ERROR {
			op.callback(completion.user_data, op.read, FS_Error(err))
		} else if op.all && read > 0 && op.read < op.len {
			op.buf = op.buf[read:]
			op.offset += int(read)

			op.pending = false

			handle_completion(io, completion)
			return
		} else {
			op.callback(completion.user_data, op.read, nil)
		}

	case Op_Write:
		written, err := write_callback(io, completion, &op)
		if err_incomplete(err) {
			io.io_pending += 1
			return
		}

		op.written += int(written)

		oerr := FS_Error(err)
		if oerr != nil {
			op.callback(completion.user_data, op.written, oerr)
		} else if op.all && op.written < op.len {
			op.buf = op.buf[written:]
			op.offset += int(written)

			op.pending = false

			handle_completion(io, completion)
			return
		} else {
			op.callback(completion.user_data, op.written, nil)
		}

	case Op_Recv:
		received, err := recv_callback(io, completion, &op)
		if wsa_err_incomplete(err) {
			io.io_pending += 1
			return
		}

		op.received += int(received)

		if err != nil {
			op.callback.(On_Recv_TCP)(completion.user_data, op.received, err)
		} else if op.all && received > 0 && op.received < op.len {
			op.buf = win.WSABUF{
				len = op.buf.len - win.ULONG(received),
				buf = (cast([^]byte)op.buf.buf)[received:],
			}
			op.pending = false

			handle_completion(io, completion)
			return
		} else {
			op.callback.(On_Recv_TCP)(completion.user_data, op.received, nil)
		}

	case Op_Send:
		sent, err := send_callback(io, completion, &op)
		if wsa_err_incomplete(err) {
			io.io_pending += 1
			return
		}

		op.sent += int(sent)

		if err != nil {
			op.callback.(On_Sent_TCP)(completion.user_data, op.sent, err)
		} else if op.all && op.sent < op.len {
			op.buf = win.WSABUF{
				len = op.buf.len - win.ULONG(sent),
				buf = (cast([^]byte)op.buf.buf)[sent:],
			}
			op.pending = false

			handle_completion(io, completion)
			return
		} else {
			op.callback.(On_Sent_TCP)(completion.user_data, op.sent, nil)
		}

	case Op_Timeout:
		op.callback(completion.user_data)
	case Op_Next_Tick:
		if completion.timeout != (^Completion)(REMOVED) {
			op.callback(completion.user_data)
		}
	case Op_Poll, Op_Remove:
		unreachable()
	}

	completed = true
	pool_put(&io.completion_pool, completion)
}

accept_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Accept) -> (source: net.Endpoint, err: net.Accept_Error) {
	ok: win.BOOL
	if op.pending {
		// Get status update, we've already initiated the accept.
		flags: win.DWORD
		transferred: win.DWORD
		ok = win.WSAGetOverlappedResult(op.socket, &comp.over, &transferred, win.FALSE, &flags)
	} else {
		op.pending = true

		oclient, oerr := _open_socket(io, .IP4, .TCP)
		// TODO:
		ensure(oerr == nil)

		op.client = win.SOCKET(net.any_socket_to_socket(oclient))

		accept_ex: LPFN_ACCEPTEX
		load_socket_fn(op.socket, win.WSAID_ACCEPTEX, &accept_ex)

		#assert(size_of(win.SOCKADDR_STORAGE_LH) >= size_of(win.sockaddr_in) + 16)
		bytes_read: win.DWORD
		ok = accept_ex(
			op.socket,
			op.client,
			&op.addr,
			0,
			size_of(win.sockaddr_in) + 16,
			size_of(win.sockaddr_in) + 16,
			&bytes_read,
			&comp.over,
		)
	}

	if !ok {
		err = net._accept_error()
		return
	}

	// enables getsockopt, setsockopt, getsockname, getpeername.
	win.setsockopt(op.client, win.SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, nil, 0)

	source = sockaddr_to_endpoint(&op.addr)
	return
}

connect_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Connect) -> (err: net.Network_Error) {
	transferred: win.DWORD
	ok: win.BOOL
	if op.pending {
		flags: win.DWORD
		ok = win.WSAGetOverlappedResult(op.socket, &comp.over, &transferred, win.FALSE, &flags)
	} else {
		op.pending = true

		osocket := _open_socket(io, .IP4, .TCP) or_return

		op.socket = win.SOCKET(net.any_socket_to_socket(osocket))

		sockaddr := endpoint_to_sockaddr({net.IP4_Any, 0})
		res := win.bind(op.socket, &sockaddr, size_of(sockaddr))
		if res < 0 { return net._bind_error() }

		connect_ex: LPFN_CONNECTEX
		load_socket_fn(op.socket, WSAID_CONNECTEX, &connect_ex)
		// TODO: size_of(win.sockaddr_in6) when ip6.
		ok = connect_ex(op.socket, &op.addr, size_of(win.sockaddr_in) + 16, nil, 0, &transferred, &comp.over)
	}
	if !ok { return net._dial_error() }

	// enables getsockopt, setsockopt, getsockname, getpeername.
	win.setsockopt(op.socket, win.SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, nil, 0)
	return
}

close_callback :: proc(io: ^IO, op: Op_Close) -> FS_Error {
	// NOTE: This might cause problems if there is still IO queued/pending.
	// Is that our responsibility to check/keep track of?
	// Might want to call win.CancelloEx to cancel all pending operations first.

	switch h in op.fd {
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
	case net.Socket:
		if win.closesocket(win.SOCKET(h)) != win.NO_ERROR {
			return FS_Error(win.WSAGetLastError())
		}
	case:
		unreachable()
	}

	return nil
}

read_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Read) -> (read: win.DWORD, err: win.DWORD) {
	ok: win.BOOL
	if op.pending {
		ok = win.GetOverlappedResult(win.HANDLE(op.fd), &comp.over, &read, win.FALSE)
	} else {
		comp.over.Offset = u32(op.offset)
		// TODO: this is wrong.
		comp.over.OffsetHigh = comp.over.Offset >> 32

		// TODO: MAX_RW?

		ok = win.ReadFile(win.HANDLE(op.fd), raw_data(op.buf), win.DWORD(len(op.buf)), &read, &comp.over)

		// Not sure if this also happens with correctly set up handles some times.
		if ok {
			log.info("non-blocking write returned immediately, is the handle set up correctly?")
		}

		op.pending = true
	}

	if !ok { err = win.GetLastError() }

	return
}

write_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Write) -> (written: win.DWORD, err: win.DWORD) {
	ok: win.BOOL
	if op.pending {
		ok = win.GetOverlappedResult(win.HANDLE(op.fd), &comp.over, &written, win.FALSE)
	} else {
		comp.over.Offset = u32(op.offset)
		// TODO: this is wrong.
		comp.over.OffsetHigh = comp.over.Offset >> 32

		// TODO: MAX_RW?

		ok = win.WriteFile(win.HANDLE(op.fd), raw_data(op.buf), win.DWORD(len(op.buf)), &written, &comp.over)

		// Not sure if this also happens with correctly set up handles some times.
		if ok {
			log.debug("non-blocking write returned immediately, is the handle set up correctly?")
		}

		op.pending = true
	}

	if !ok { err = win.GetLastError() }

	return
}

recv_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Recv) -> (received: win.DWORD, err: net.TCP_Recv_Error) {
	sock := win.SOCKET(net.any_socket_to_socket(op.socket))
	ok: win.BOOL
	if op.pending {
		flags: win.DWORD
		ok = win.WSAGetOverlappedResult(sock, &comp.over, &received, win.FALSE, &flags)
	} else {
		flags: win.DWORD

		buf := op.buf
		buf.len = min(buf.len, MAX_RW)

		err_code := win.WSARecv(sock, &buf, 1, &received, &flags, win.LPWSAOVERLAPPED(&comp.over), nil)
		ok = err_code != win.SOCKET_ERROR
		op.pending = true
	}

	if !ok { err = net._tcp_recv_error() }
	return
}

send_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Send) -> (sent: win.DWORD, err: net.TCP_Send_Error) {
	sock := win.SOCKET(net.any_socket_to_socket(op.socket))
	ok: win.BOOL
	if op.pending {
		flags: win.DWORD
		ok = win.WSAGetOverlappedResult(sock, &comp.over, &sent, win.FALSE, &flags)
	} else {
		buf := op.buf
		buf.len = min(buf.len, MAX_RW)

		err_code := win.WSASend(sock, &buf, 1, &sent, 0, win.LPWSAOVERLAPPED(&comp.over), nil)
		ok = err_code != win.SOCKET_ERROR
		op.pending = true
	}

	if !ok { err = net._tcp_send_error() }
	return
}

FILE_SKIP_COMPLETION_PORT_ON_SUCCESS :: 0x1
FILE_SKIP_SET_EVENT_ON_HANDLE :: 0x2

SO_UPDATE_ACCEPT_CONTEXT :: 28683

WSAID_CONNECTEX :: win.GUID{0x25a207b9, 0xddf3, 0x4660, [8]win.BYTE{0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e}}

LPFN_CONNECTEX :: #type proc "stdcall" (
	socket: win.SOCKET,
	addr: ^win.SOCKADDR_STORAGE_LH,
	namelen: win.c_int,
	send_buf: win.PVOID,
	send_data_len: win.DWORD,
	bytes_sent: win.LPDWORD,
	overlapped: win.LPOVERLAPPED,
) -> win.BOOL

LPFN_ACCEPTEX :: #type proc "stdcall" (
	listen_sock: win.SOCKET,
	accept_sock: win.SOCKET,
	addr_buf: win.PVOID,
	addr_len: win.DWORD,
	local_addr_len: win.DWORD,
	remote_addr_len: win.DWORD,
	bytes_received: win.LPDWORD,
	overlapped: win.LPOVERLAPPED,
) -> win.BOOL

wsa_err_incomplete :: proc(err: $T) -> bool {
	when T == net.Dial_Error {
		if err == .Already_Connecting {
			return true
		}
	}

	when T != net.Network_Error {
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

err_incomplete :: proc(err: win.DWORD) -> bool {
	return err == win.ERROR_IO_PENDING
}

// Verbatim copy of private proc in core:net.
sockaddr_to_endpoint :: proc(native_addr: ^win.SOCKADDR_STORAGE_LH) -> (ep: net.Endpoint) {
	switch native_addr.ss_family {
	case u16(win.AF_INET):
		addr := cast(^win.sockaddr_in)native_addr
		port := int(addr.sin_port)
		ep = net.Endpoint {
			address = net.IP4_Address(transmute([4]byte)addr.sin_addr),
			port    = port,
		}
	case u16(win.AF_INET6):
		addr := cast(^win.sockaddr_in6)native_addr
		port := int(addr.sin6_port)
		ep = net.Endpoint {
			address = net.IP6_Address(transmute([8]u16be)addr.sin6_addr),
			port    = port,
		}
	case:
		panic("native_addr is neither IP4 or IP6 address")
	}
	return
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

// TODO: loading this takes a overlapped parameter, maybe we can do this async?
load_socket_fn :: proc(subject: win.SOCKET, guid: win.GUID, fn: ^$T) {
	guid := guid
	bytes: u32
	rc := win.WSAIoctl(
		subject,
		win.SIO_GET_EXTENSION_FUNCTION_POINTER,
		&guid,
		size_of(guid),
		fn,
		size_of(fn),
		&bytes,
		nil,
		nil,
	)
	assert(rc != win.SOCKET_ERROR)
	assert(bytes == size_of(fn^))
}
