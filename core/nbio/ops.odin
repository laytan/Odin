package nbio

import "base:intrinsics"

import "core:net"
import "core:time"
import "core:container/pool"

// TODO: multi variant of accept that keeps accepting new connections.

// TODO: multi variant of timeout calling on an interval.

// TODO: sendfile

Accept :: struct {
	socket:  TCP_Socket,
	timeout: time.Duration,

	client:          TCP_Socket,
	client_endpoint: net.Endpoint,
	err:             net.Accept_Error,

	// Implementation specifics, private.
	_impl: _Accept,
}

prep_accept :: #force_inline proc(socket: TCP_Socket, cb: Callback, timeout: time.Duration = 0, l: ^Event_Loop = nil) -> ^Operation {
	op := _prep(l, cb, .Accept)
	op.accept.socket  = socket
	op.accept.timeout = timeout
	return op
}

/*
Using the given socket, accepts the next incoming connection, calling the callback when that happens

NOTE: polymorphic variants for type safe user data are available under `accept_poly`, `accept_poly2`, and `accept_poly3`.

Inputs:
- socket: A bound and listening socket *that was created using this package*
*/
accept :: #force_inline proc(socket: TCP_Socket, user_data: rawptr, cb: Callback, timeout: time.Duration = 0, l: ^Event_Loop = nil) -> ^Operation {
	res := prep_accept(socket, cb, timeout, l)
	res.user_data[0] = user_data
	exec(res)
	return res
}

accept_poly :: #force_inline proc(socket: TCP_Socket, p: $T, cb: $C/proc(op: ^Operation, p: T), timeout: time.Duration = 0, l: ^Event_Loop = nil) -> ^Operation
where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_accept(socket, _poly_cb(C, T), timeout, l)
	_put_user_data(op, cb, p)
	exec(op)
	return op
}

accept_poly2 :: #force_inline proc(socket: TCP_Socket, p: $T, p2: $T2, cb: $C/proc(op: ^Operation, p: T, p2: T2), timeout: time.Duration = 0, l: ^Event_Loop = nil) -> ^Operation
where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_accept(socket, _poly_cb2(C, T, T2), timeout, l)
	_put_user_data2(op, cb, p, p2)
	exec(op)
	return op
}

accept_poly3 :: #force_inline proc(socket: TCP_Socket, p: $T, p2: $T2, p3: $T3, cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3), timeout: time.Duration = 0, l: ^Event_Loop = nil) -> ^Operation
where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_accept(socket, _poly_cb3(C, T, T2, T3), timeout, l)
	_put_user_data3(op, cb, p, p2, p3)
	exec(op)
	return op
}

/*
A union of types that are `close`'able by this package
*/
Closable :: union #no_nil {
	TCP_Socket,
	UDP_Socket,
	Handle,
}

Close :: struct {
	subject: Closable,

	err: FS_Error,

	// Implementation specifics, private.
	_impl:   _Close,
}

empty_callback :: proc(_: ^Operation) {}

prep_close :: #force_inline proc(subject: Closable, cb: Callback = empty_callback, l: ^Event_Loop = nil) -> ^Operation {
	op := _prep(l, cb, .Close)
	op.close.subject = subject
	return op
}

close :: #force_inline proc(subject: Closable, user_data: rawptr = nil, cb: Callback = empty_callback, l: ^Event_Loop = nil) -> ^Operation {
	op := prep_close(subject, cb, l=l)
	op.user_data[0] = user_data
	exec(op)
	return op
}

close_poly :: #force_inline proc(subject: Closable, p: $T, cb: $C/proc(op: ^Operation, p: T), l: ^Event_Loop = nil) -> ^Operation
where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_close(subject, _poly_cb(C, T), l=l)
	_put_user_data(op, cb, p)
	exec(op)
	return op
}

close_poly2 :: #force_inline proc(subject: Closable, p: $T, p2: $T2, cb: $C/proc(op: ^Operation, p: T, p2: T2), l: ^Event_Loop = nil) -> ^Operation
where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_close(subject, _poly_cb2(C, T, T2), l)
	_put_user_data2(op, cb, p, p2)
	exec(op)
	return op
}

close_poly3 :: #force_inline proc(subject: Closable, p: $T, p2: $T2, p3: $T3, cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3), l: ^Event_Loop = nil) -> ^Operation
where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_close3(subject, _poly_cb3(C, T, T2, T3), l)
	_put_user_data3(op, cb, p, p2, p3)
	exec(op)
	return op
}

Dial :: struct {
	endpoint: net.Endpoint,
	timeout:  time.Duration,

	// Errors that can be returned: `Create_Socket_Error`, or `Dial_Error`.
	err:      net.Network_Error,
	socket:   TCP_Socket,

	// Implementation specifics, private.
	_impl:    _Dial,
}

prep_dial :: #force_inline proc(endpoint: net.Endpoint, cb: Callback, timeout: time.Duration = 0, l: ^Event_Loop = nil) -> ^Operation {
	op := _prep(l, cb, .Dial)
	op.dial.timeout  = timeout
	op.dial.endpoint = endpoint
	return op
}

dial :: #force_inline proc(
	endpoint: net.Endpoint,
	user_data: rawptr,
	cb: Callback,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	res := prep_dial(endpoint, cb, timeout, l)
	res.user_data[0] = user_data
	exec(res)
	return res
}

dial_poly :: #force_inline proc(
	endpoint: net.Endpoint,
	p: $T,
	cb: $C/proc(op: ^Operation, p: T),
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_dial(endpoint, _poly_cb(C, T), timeout, l)
	_put_user_data(op, cb, p)
	exec(op)

	return op
}

dial_poly2 :: #force_inline proc(
	endpoint: net.Endpoint,
	p: $T, p2: $T2,
	cb: $C/proc(op: ^Operation, p: T, p2: T2),
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_dial(endpoint, _poly_cb2(C, T, T2), timeout, l)
	_put_user_data2(op, cb, p, p2)
	exec(op)

	return op
}

dial_poly3 :: #force_inline proc(
	endpoint: net.Endpoint,
	p: $T, p2: $T2, p3: $T3,
	cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3),
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_dial(endpoint, _poly_cb3(C, T, T2, T3), timeout, l)
	_put_user_data3(op, cb, p, p2, p3)
	exec(op)

	return op
}

Recv :: struct {
	socket:   Any_Socket,
	buf:      []byte,
	all:      bool,
	timeout:  time.Duration,

	source:   net.Endpoint,
	err:      net.Recv_Error,
	received: int,

	// Implementation specifics, private.
	_impl:    _Recv,
}

prep_recv :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	cb: Callback,
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := _prep(l, cb, .Recv)
	op.recv.socket  = socket
	op.recv.buf     = buf
	op.recv.all     = all
	op.recv.timeout = timeout
	return op
}

recv :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	user_data: rawptr,
	cb: Callback,
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil
) -> ^Operation {
	op := prep_recv(socket, buf, cb, all, timeout, l)
	op.user_data[0] = user_data
	exec(op)
	return op
}

recv_poly :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	p: $T,
	cb: $C/proc(op: ^Operation, p: T),
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_recv(socket, buf, _poly_cb(C, T), all, timeout, l)
	_put_user_data(op, cb, p)
	exec(op)

	return op
}

recv_poly2 :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	p: $T, p2: $T2,
	cb: $C/proc(op: ^Operation, p: T, p2: T2),
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_recv(socket, buf, _poly_cb2(C, T, T2), all, timeout, l)
	_put_user_data2(op, cb, p, p2)
	exec(op)

	return op
}

recv_poly3 :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	p: $T, p2: $T2, p3: $T3,
	cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3),
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_recv(socket, buf, _poly_cb2(C, T, T2), all, timeout, l)
	_put_user_data2(op, cb, p, p2)
	exec(op)

	return op
}

Send :: struct {
	socket:   Any_Socket,
	buf:      []byte,
	endpoint: net.Endpoint,
	all:      bool,
	timeout:  time.Duration,

	err:      net.Send_Error,
	sent:     int,

	// Implementation specifics, private.
	_impl:    _Send,
}

prep_send :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	cb: Callback,
	endpoint: net.Endpoint = {},
	all := true,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := _prep(l, cb, .Send)
	op.send.socket   = socket
	op.send.buf      = buf
	op.send.endpoint = endpoint
	op.send.all      = all
	op.send.timeout  = timeout
	return op
}

send :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	user_data: rawptr,
	cb: Callback,
	endpoint: net.Endpoint = {},
	all := true,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := prep_send(socket, buf, cb, endpoint, all, timeout, l)
	op.user_data[0] = user_data
	exec(op)
	return op
}

send_poly :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	p: $T,
	cb: $C/proc(op: ^Operation, p: T),
	endpoint: net.Endpoint = {},
	all := true,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_send(socket, buf, _poly_cb(C, T), endpoint, all, timeout, l)
	_put_user_data(op, cb, p)
	exec(op)

	return op
}

send_poly2 :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	p: $T, p2: $T2,
	cb: $C/proc(op: ^Operation, p: T, p2: T2),
	endpoint: net.Endpoint = {},
	all := true,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_send(socket, buf, _poly_cb2(C, T, T2), endpoint, all, timeout, l)
	_put_user_data2(op, cb, p, p2)
	exec(op)

	return op
}

send_poly3 :: #force_inline proc(
	socket: Any_Socket,
	buf: []byte,
	p: $T, p2: $T2, p3: $T3,
	cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3),
	endpoint: net.Endpoint = {},
	all := true,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_send(socket, buf, _poly_cb3(C, T, T2, T3), endpoint, all, timeout, l)
	_put_user_data3(op, cb, p, p2, p3)
	exec(op)

	return op
}

Read :: struct {
	fd:      Handle,
	buf:     []byte,
	offset:	 int,
	all:   	 bool,
	timeout: time.Duration,

	err:     FS_Error,
	read:  	 int,

	// Implementation specifics, private.
	_impl:  _Read,
}

prep_read :: #force_inline proc(
	fd: Handle,
	buf: []byte,
	offset: int,
	cb: Callback,
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := _prep(l, cb, .Read)
	op.read.fd      = fd
	op.read.buf     = buf
	op.read.offset  = offset
	op.read.all     = all
	op.read.timeout = timeout
	return op
}

read :: #force_inline proc(
	fd: Handle,
	buf: []byte,
	offset: int,
	user_data: rawptr,
	cb: Callback,
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := prep_read(fd, buf, offset, cb, all, timeout, l)
	op.user_data[0] = user_data
	exec(op)
	return op
}

read_poly :: #force_inline proc(
	fd: Handle,
	buf: []byte,
	offset: int,
	p: $T,
	cb: $C/proc(op: ^Operation, p: T),
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil
) -> ^Operation where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_read(fd, buf, offset, _poly_cb(C, T), all=all, timeout=timeout, l=l)
	_put_user_data(op, cb, p)
	exec(op)

	return op
}

read_poly2 :: #force_inline proc(
	fd: Handle,
	buf: []byte,
	offset: int,
	p: $T, p2: $T2,
	cb: $C/proc(op: ^Operation, p: T, p2: T2),
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil
) -> ^Operation where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_read(fd, buf, offset, _poly_cb2(C, T, T2), all, timeout, l)
	_put_user_data2(op, cb, p, p2)
	exec(op)

	return op
}

read_poly3 :: #force_inline proc(
	fd: Handle,
	buf: []byte,
	offset: int,
	p: $T, p2: $T2, p3: $T3,
	cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3),
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil
) -> ^Operation where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_read(fd, buf, offset, _poly_cb3(C, T, T2, T3), all, timeout, l)
	_put_user_data3(op, cb, p, p2, p3)
	exec(op)

	return op
}

Write :: struct {
	fd:      Handle,
	buf:     []byte,
	offset:  int,
	all:     bool,
	timeout: time.Duration,

	err:     FS_Error,
	written: int,

	// Implementation specifics, private.
	_impl:   _Write,
}

prep_write :: #force_inline proc(
	fd: Handle,
	buf: []byte,
	offset: int,
	cb: Callback,
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := _prep(l, cb, .Write)
	op.write.fd      = fd
	op.write.buf     = buf
	op.write.offset  = offset
	op.write.all     = all
	op.write.timeout = timeout
	return op
}

write :: #force_inline proc(
	fd: Handle,
	buf: []byte,
	offset: int,
	user_data: rawptr,
	cb: Callback,
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := prep_write(fd, buf, offset, cb, all, timeout, l)
	op.user_data[0] = user_data
	exec(op)
	return op
}

write_poly :: #force_inline proc(
	fd: Handle,
	offset: int,
	buf: []byte,
	p: $T,
	cb: $C/proc(op: ^Operation, p: T),
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil
) -> ^Operation where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_write(fd, offset, buf, _poly_cb(C, T), all=all, timeout=timeout, l=l)
	_put_user_data(op, cb, p)
	exec(op)

	return op
}

write_poly2 :: #force_inline proc(
	fd: Handle,
	offset: int,
	buf: []byte,
	p: $T, p2: $T2,
	cb: $C/proc(op: ^Operation, p: T, p2: T2),
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil
) -> ^Operation where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_write(fd, offset, buf, _poly_cb2(C, T, T2), all, timeout, l)
	_put_user_data2(op, cb, p, p2)
	exec(op)

	return op
}

write_poly3 :: #force_inline proc(
	fd: Handle,
	offset: int,
	buf: []byte,
	p: $T, p2: $T2, p3: $T3,
	cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3),
	all := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil
) -> ^Operation where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_write(fd, offset, buf, _poly_cb3(C, T, T2, T3), all, timeout, l)
	_put_user_data3(op, cb, p, p2, p3)
	exec(op)

	return op
}

Timeout :: struct {
	duration: time.Duration,

	// Implementation specifics, private.
	_impl:    _Timeout,
}

prep_timeout :: #force_inline proc(duration: time.Duration, cb: Callback, l: ^Event_Loop = nil) -> ^Operation {
	op := _prep(l, cb, .Timeout)
	op.timeout.duration = duration
	return op
}

timeout :: #force_inline proc(duration: time.Duration, user_data: rawptr, cb: Callback, l: ^Event_Loop = nil) -> ^Operation {
	op := prep_timeout(duration, cb, l)
	op.user_data[0] = user_data
	exec(op)
	return op
}

timeout_poly :: #force_inline proc(dur: time.Duration, p: $T, cb: $C/proc(op: ^Operation, p: T), l: ^Event_Loop = nil) -> ^Operation
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_timeout(dur, _poly_cb(C, T), l)
	_put_user_data(op, cb, p)
	exec(op)

	return op
}

timeout_poly2 :: #force_inline proc(dur: time.Duration, p: $T, p2: $T2, cb: $C/proc(op: ^Operation, p: T, p2: T2), l: ^Event_Loop = nil) -> ^Operation
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_timeout(dur, _poly_cb2(C, T, T2), l)
	_put_user_data2(op, cb, p, p2)
	exec(op)

	return op
}

timeout_poly3 :: #force_inline proc(dur: time.Duration, p: $T, p2: $T2, p3: $T3, cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3), l: ^Event_Loop = nil) -> ^Operation
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_timeout(dur, _poly_cb3(C, T, T2, T3), l)
	_put_user_data3(op, cb, p, p2, p3)
	exec(op)

	return op
}

prep_next_tick :: #force_inline proc(cb: Callback, l: ^Event_Loop = nil) -> ^Operation {
	return prep_timeout(0, cb, l)
}

next_tick :: #force_inline proc(user_data: rawptr, cb: Callback, l: ^Event_Loop = nil) -> ^Operation {
	return timeout(0, user_data, cb, l)
}

next_tick_poly :: #force_inline proc(p: $T, cb: $C/proc(op: ^Operation, p: T), l: ^Event_Loop = nil) -> ^Operation
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	return timeout_poly(0, p, cb, l)
}

next_tick_poly2 :: #force_inline proc(p: $T, p2: $T2, cb: $C/proc(op: ^Operation, p: T, p2: T2), l: ^Event_Loop = nil) -> ^Operation
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	return timeout_poly2(0, p, p2, cb, l)
}

next_tick_poly3 :: #force_inline proc(p: $T, p2: $T2, p3: $T3, cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3), l: ^Event_Loop = nil) -> ^Operation
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	return timeout_poly3(0, p, p2, p3, cb, l)
}

Poll_Result :: enum i32 {
	Ready,
	Unsupported,
	Timeout,
	Invalid_Argument,
	Error,
}

Poll_Event :: enum {
	// The subject is ready to be read from.
	Read,
	// The subject is ready to be written to.
	Write,
}

Poll :: struct {
	socket:  Any_Socket,
	events:  bit_set[Poll_Event],
	multi:   bool,
	timeout: time.Duration,

	result_events: bit_set[Poll_Event],
	result:       Poll_Result,

	// Implementation specifics, private.
	_impl:  _Poll,
}

prep_poll :: #force_inline proc(
	socket: Any_Socket,
	events: bit_set[Poll_Event],
	cb: Callback,
	multi := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := _prep(l, cb, .Poll)
	op.poll.socket  = socket
	op.poll.events  = events
	op.poll.multi   = multi
	op.poll.timeout = timeout
	return op
}

poll :: #force_inline proc(
	socket: Any_Socket,
	events: bit_set[Poll_Event],
	user_data: rawptr,
	cb: Callback,
	multi := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := prep_poll(socket, events, cb, multi, timeout, l)
	op.user_data[0] = user_data
	exec(op)
	return op
}

poll_poly :: #force_inline proc(
	socket: Any_Socket,
	events: bit_set[Poll_Event],
	p: $T,
	cb: $C/proc(op: ^Operation, p: T),
	multi := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_poll(socket, events, _poly_cb(C, T), multi, timeout, l)
	_put_user_data(op, cb, p)
	exec(op)

	return op
}

poll_poly2 :: #force_inline proc(
	socket: Any_Socket,
	events: bit_set[Poll_Event],
	p: $T, p2: $T2,
	callback: $C/proc(op: ^Operation, p: T, p2: T2),
	multi := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_poll(socket, events, _poly_cb2(C, T, T2), multi, timeout, l)
	_put_user_data2(op, cb, p, p2)
	exec(op)

	return op
}

poll_poly3 :: #force_inline proc(
	socket: Any_Socket,
	events: bit_set[Poll_Event],
	p: $T, p2: $T2, p3: $T3,
	cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3),
	multi := false,
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_poll(socket, events, _poly_cb3(C, T, T2, T3), multi, timeout, l)
	_put_user_data3(op, cb, p, p2, p3)
	exec(op)

	return op
}

Send_File :: struct {
	socket:  Any_Socket,
	file:    Handle,
	timeout: time.Duration,

	size: int,

	sent: int,
	err:  FS_Error,

	// Implementation specifics, private.
	_impl: _Send_File,
}

prep_sendfile :: #force_inline proc(socket: Any_Socket, file: Handle, cb: Callback, timeout: time.Duration = 0, l: ^Event_Loop = nil) -> ^Operation {
	op := _prep(l, cb, .Send_File)
	op.sendfile.socket  = socket
	op.sendfile.file    = file
	op.sendfile.timeout = timeout
	return op
}

sendfile :: #force_inline proc(socket: Any_Socket, file: Handle, user_data: rawptr, cb: Callback, timeout: time.Duration = 0, l: ^Event_Loop = nil) -> ^Operation {
	op := prep_sendfile(socket, file, cb, timeout, l)
	op.user_data[0] = user_data
	exec(op)
	return op
}

// TODO: len and offset
sendfile_poly :: #force_inline proc(
	socket: Any_Socket,
	file:   Handle,
	p: $T,
	cb: $C/proc(op: ^Operation, p: T),
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_sendfile(socket, file, _poly_cb(C, T), timeout, l)
	_put_user_data(op, cb, p)
	exec(op)

	return op
}

sendfile_poly2 :: #force_inline proc(
	socket: Any_Socket,
	file:   Handle,
	p: $T, p2: $T2,
	callback: $C/proc(op: ^Operation, p: T, p2: T2),
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_sendfile(socket, file, _poly_cb2(C, T, T2), timeout, l)
	_put_user_data2(op, cb, p, p2)
	exec(op)

	return op
}

sendfile_poly3 :: #force_inline proc(
	socket: Any_Socket,
	file:   Handle,
	p: $T, p2: $T2, p3: $T3,
	cb: $C/proc(op: ^Operation, p: T, p2: T2, p3: T3),
	timeout: time.Duration = 0,
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {

	op := prep_sendfile(socket, file, _poly_cb3(C, T, T2, T3), timeout, l)
	_put_user_data3(op, cb, p, p2, p3)
	exec(op)

	return op
}

@(private)
_prep :: proc(l: ^Event_Loop, cb: Callback, type: Operation_Type, loc := #caller_location) -> ^Operation {
	l := l
	if l == nil { l = _current_thread_event_loop(loc) }
	operation := pool.get(&l.operation_pool)
	operation.l = l
	operation.ctx = context
	operation.type = type
	operation.cb = cb
	return operation
}

@(private="file")
_poly_cb :: #force_inline proc($C: typeid, $T: typeid) -> proc(^Operation) {
	return proc(op: ^Operation) {
		ptr := uintptr(&op.user_data)
		cb  := intrinsics.unaligned_load((^C)(rawptr(ptr)))
		p   := intrinsics.unaligned_load((^T)(rawptr(ptr + size_of(C))))
		cb(op, p)
	}
}

@(private="file")
_poly_cb2 :: #force_inline proc($C: typeid, $T: typeid, $T2: typeid) -> proc(^Operation) {
	return proc(op: ^Operation) {
		ptr := uintptr(&op.user_data)
		cb  := intrinsics.unaligned_load((^C) (rawptr(ptr)))
		p   := intrinsics.unaligned_load((^T) (rawptr(ptr + size_of(C))))
		p2  := intrinsics.unaligned_load((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(op, p, p2)
	}
}

@(private="file")
_poly_cb3 :: #force_inline proc($C: typeid, $T: typeid, $T2: typeid, $T3: typeid) -> proc(^Operation) {
	return proc(op: ^Operation) {
		ptr := uintptr(&op.user_data)
		cb  := intrinsics.unaligned_load((^C) (rawptr(ptr)))
		p   := intrinsics.unaligned_load((^T) (rawptr(ptr + size_of(C))))
		p2  := intrinsics.unaligned_load((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := intrinsics.unaligned_load((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(op, p, p2, p3)
	}
}

@(private="file")
_put_user_data :: #force_inline proc(op: ^Operation, cb: $C, p: $T) {
	ptr := uintptr(&op.user_data)
	intrinsics.unaligned_store((^C)(rawptr(ptr)),               cb)
	intrinsics.unaligned_store((^T)(rawptr(ptr + size_of(cb))), p)
}

@(private="file")
_put_user_data2 :: #force_inline proc(op: ^Operation, cb: $C, p: $T, p2: $T2) {
	ptr := uintptr(&op.user_data)
	intrinsics.unaligned_store((^C) (rawptr(ptr)),                            cb)
	intrinsics.unaligned_store((^T) (rawptr(ptr + size_of(cb))),              p)
	intrinsics.unaligned_store((^T2)(rawptr(ptr + size_of(cb) + size_of(p))), p2)
}

@(private="file")
_put_user_data3 :: #force_inline proc(op: ^Operation, cb: $C, p: $T, p2: $T2, p3: $T3) {
	ptr := uintptr(&op.user_data)
	intrinsics.unaligned_store((^C) (rawptr(ptr)),                                          cb)
	intrinsics.unaligned_store((^T) (rawptr(ptr + size_of(cb))),                            p)
	intrinsics.unaligned_store((^T2)(rawptr(ptr + size_of(cb) + size_of(p))),               p2)
	intrinsics.unaligned_store((^T3)(rawptr(ptr + size_of(cb) + size_of(p) + size_of(p2))), p3)
}
