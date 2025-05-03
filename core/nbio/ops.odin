package nbio

import "base:runtime"
import "core:net"
import "core:time"

// TODO: should this be configurable, with a minimum of course for the use of core?
MAX_USER_ARGUMENTS :: 5

Completion :: struct {

	next: ^Completion,

	ctx: runtime.Context,
	op:  Operation,

	user_data: [MAX_USER_ARGUMENTS + 2]rawptr,

	// Implementation specifics, private.
	_impl:   _Completion,
}

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

	_Op_Remove,
}

// TODO: multi variant that keeps accepting new connections.
Op_Accept :: struct {
	cb:    On_Accept,
	sock:  net.TCP_Socket,

	// Implementation specifics, private.
	_impl: _Op_Accept,
}

@(private)
prep :: proc(io: ^IO, user: rawptr) -> ^Completion {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.io = io
	completion.user_data[0] = user
	return completion
}

@(private)
exec :: proc(completion: ^Completion) {
	// MPSC? do we need a different queue for current or other thread?
	if completion.io == g_io {
		// current thread
	} else {
		// other thread
	}
}

prep_accept :: proc(socket: net.TCP_Socket, cb: On_Accept, user: rawptr = nil, io: Maybe(^IO) = nil) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Accept {
		cb     = cb,
		socket = socket,
	}
	return completion
}

Op_Close :: struct {
	cb:      On_Close,
	subject: Closable,

	// Implementation specifics, private.
	_impl:   _Op_Accept,
}

prep_close :: proc(subject: Closable, cb: On_Close, user: rawptr = nil, io: Maybe(^IO) = nil) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Close {
		cb      = cb,
		subject = subject,
	}
	return completion
}

Op_Dial :: struct {
	cb:       On_Dial,
	endpoint: net.Endpoint,
	socket:   net.TCP_Socket,

	// Implementation specifics, private.
	_impl:    _Op_Dial,
}

prep_dial :: proc(endpoint: net.Endpoint, cb: On_Dial, user: rawptr = nil, io: Maybe(^IO) = nil) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Dial{
		cb       = cb,
		endpoint = endpoint,
	}
	return completion
}

Op_Recv :: struct {
	cb:       On_Recv,
	socket:   net.Any_Socket,
	buf:      []byte,
	all:      bool,
	received: int,

	// Implementation specifics, private.
	_impl:    _Op_Recv,
}

prep_recv :: proc(
	socket: net.Any_Socket,
	buf: []byte,
	cb: On_Recv,
	all := false,
	user: rawptr = nil,
	io: Maybe(^IO) = nil,
) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Recv{
		cb     = cb,
		socket = endpoint,
		buf    = buf,
		all    = all,
	}
	return completion
}

Op_Send :: struct {
	cb:       On_Sent,
	socket:   net.Any_Socket,
	buf:      []byte,
	endpoint: net.Endpoint,
	all:      bool,
	sent:     int,

	// Implementation specifics, private.
	_impl:    _Op_Send,
}

prep_send :: proc(
	socket: net.Any_Socket,
	buf: []byte,
	cb: On_Sent,
	endpoint: net.Endpoint = {},
	all := false,
	user: rawptr = nil,
	io: Maybe(^IO) = nil,
) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Send{
		cb       = cb,
		socket   = endpoint,
		buf      = buf,
		endpoint = endpoint,
		all      = all,
	}
	return completion
}

Op_Read :: struct {
	cb:     On_Read,
	fd:     Handle,
	buf:    []byte,
	offset:	int,
	all:   	bool,
	read:  	int,

	// Implementation specifics, private.
	_impl:  _Op_Read,
}

prep_read :: proc(
	fd: Handle,
	buf: []byte,
	offset: int,
	cb: On_Read,
	all := false,
	user: rawptr = nil,
	io: Maybe(^IO) = nil,
) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Read{
		cb     = cb,
		fd     = fd,
		buf    = buf,
		offset = offset,
		all    = all,
	}
	return completion
}

Op_Write :: struct {
	cb:      On_Write,
	fd:      Handle,
	buf:     []byte,
	offset:  int,
	all:     bool,
	written: int,

	// Implementation specifics, private.
	_impl:   _Op_Write,
}

prep_write :: proc(
	fd: Handle,
	buf: []byte,
	offset: int,
	cb: On_Write,
	all := false,
	user: rawptr = nil,
	io: Maybe(^IO) = nil,
) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Write{
		cb     = cb,
		fd     = fd,
		buf    = buf,
		offset = offset,
		all    = all,
	}
	return completion
}

// TODO: multi variant, calling on an interval.
Op_Timeout :: struct {
	cb:       On_Timeout,
	duration: time.Duration,

	// Implementation specifics, private.
	_impl:    _Op_Timeout,
}

prep_timeout :: proc(duration: time.Duration, cb: On_Timeout, user: rawptr = nil, io: Maybe(^IO) = nil) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Timeout{
		cb       = cb,
		duration = duration,
	}
	return completion
}

Op_Next_Tick :: struct {
	cb:    On_Next_Tick,

	// Implementation specifics, private.
	_impl: _Op_Next_Tick,
}

prep_next_tick :: proc(cb: On_Next_Tick, user: rawptr = nil, io: Maybe(^IO) = nil) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Next_Tick{
		cb = cb,
	}
	return completion
}

Op_Poll :: struct {
	cb:     On_Poll,
	socket: net.Any_Socket,
	event:  Poll_Event,
	multi:  bool,

	// Implementation specifics, private.
	_impl:  _Op_Poll,
}

prep_poll :: proc(
	socket: net.Any_Socket,
	event: Poll_Event,
	cb: On_Poll,
	multi := false,
	user: rawptr = nil,
	io: Maybe(^IO) = nil,
) -> ^Completion {
	completion := prep(io, user)
	completion.operation = Op_Next_Tick{
		cb = cb,
	}
	return completion
}
