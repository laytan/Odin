package nbio

import "base:intrinsics"
import "base:runtime"

import "core:net"
import "core:time"
import "core:sync/chan"
import "core:container/pool"

// TODO: find out if there's overhead to the poly calls justifying having these raw procs, otherwise remove them.

// TODO: find good spot for IDLE_TIME.

// TODO: find out if windows requires all ops on a socket/file to be done on the event loop that it was created on.

// TODO: acquire_thread_event_loop returns Event_Loop

/*
An event loop, usually one per thread, consider the fields private.
*/
Event_Loop :: struct {
	using impl:  _Event_Loop,
	err:         General_Error,
	refs:        int,
	now:         time.Time,

	// Queue/channel that is used to queue operations from another thread to be executed on this
	// thread.
	queue:          chan.Chan(^Operation),

	operation_pool: pool.Pool(Operation),
}

Handle :: _Handle

MAX_USER_ARGUMENTS :: 6

Operation :: struct {
	_impl:   _Operation,

	_pool_link: ^Operation,

	l: ^Event_Loop,

	cb: Callback,

	ctx: runtime.Context,

	using _: struct #raw_union {
		accept:   Accept,
		close:    Close,
		dial:     Dial,
		read:     Read,
		recv:     Recv,
		send:     Send,
		write:    Write,
		timeout:  Timeout,
		poll:     Poll,
		sendfile: Send_File,

		_remove:       _Remove,
		_link_timeout: _Link_Timeout,
		_splice:       _Splice,
	},
	type: Operation_Type,

	user_data: [MAX_USER_ARGUMENTS + 1]rawptr,
}

Operation_Type :: enum {
	Accept,
	Close,
	Dial,
	Read,
	Recv,
	Send,
	Write,
	Timeout,
	Poll,
	Send_File,

	_Link_Timeout,
	_Remove,
	_Splice,
}

Callback :: #type proc(op: ^Operation)

/*
Initialize or increment the reference counted event loop for the current thread.
*/
acquire_thread_event_loop :: proc() -> General_Error {
	return _acquire_thread_event_loop()
}

/*
Destroy or decrease the reference counted event loop for the current thread.
*/
release_thread_event_loop :: proc() {
	_release_thread_event_loop()
}

IDLE_TIME :: time.Millisecond * 10
#assert(IDLE_TIME % time.Millisecond == 0)

/*
Each time you call this the IO implementation checks its state
and calls any callbacks which are ready. You would typically call this in a loop.

Blocks for up-to IDLE_TIME waiting for events if there is nothing to do.

Inputs:
- io: The IO instance to tick

Returns:
- err: An error code when something went when retrieving events, 0 otherwise
*/
tick :: proc() -> General_Error {
	l := &_tls_event_loop
	if l.refs == 0 { return nil }
	return _tick(l)
}

run :: proc() -> General_Error {
	l := &_tls_event_loop
	if l.refs == 0 { return nil }

	acquire_thread_event_loop()
	defer release_thread_event_loop()

	for num_waiting() > 0 {
		if errno := _tick(l); errno != nil {
			return errno
		}
	}
	return nil
}

run_until :: proc(done: ^bool) -> General_Error {
	l := &_tls_event_loop
	if l.refs == 0 { return nil }

	acquire_thread_event_loop()
	defer release_thread_event_loop()

	for num_waiting() > 0 && !intrinsics.volatile_load(done) {
		if errno := _tick(l); errno != nil {
			return errno
		}
	}
	return nil
}

/*
Returns the number of in-progress IO to be completed.
*/
num_waiting :: proc(l: Maybe(^Event_Loop) = nil) -> int {
	l_ := l.? or_else &_tls_event_loop
	if l_.refs == 0 { return 0 }
	return pool.num_outstanding(&l_.operation_pool)
}

/*
Returns the current time (of the last tick).
*/
now :: proc() -> time.Time {
	if _tls_event_loop.now == {} {
		return time.now()
	}
	return _tls_event_loop.now
}

/*
Remove the given operation from the event loop, callback of it won't be called.

WARN: needs to be called from the thread of the event loop the target belongs to.

Common use would be to cancel a timeout, remove a polling, or remove an `accept` before calling `close` on it's socket.
*/
remove :: proc(target: ^Operation) {
	if target == nil {
		return
	}

	// TOOD: should this be allowed?
	if target.l != &_tls_event_loop {
		panic("nbio.remove called on different thread")
	}

	_remove(target)
}

TCP_Socket :: net.TCP_Socket
UDP_Socket :: net.UDP_Socket

Any_Socket :: net.Any_Socket

/*
Creates a socket, sets non blocking mode and relates it to the given IO.

WARN: do not attempt to use this package with sockets created through other means.

Inputs:
- family:   Should this be an IP4 or IP6 socket
- protocol: The type of socket (TCP or UDP)
- l:        The event loop to associate it with, defaults to the current thread's loop

Returns:
- socket: The opened socket
- err:    A network error (`Create_Socket_Error`, or `Set_Blocking_Error`) which happened while opening
*/
create_socket :: proc(
	family:   net.Address_Family,
	protocol: net.Socket_Protocol,
	l:        ^Event_Loop = nil,
	loc       := #caller_location,
) -> (
	socket: Any_Socket,
	err:    net.Network_Error,
) {
	return _create_socket(l if l != nil else _current_thread_event_loop(loc), family, protocol)
}

/*
Creates a socket, sets non blocking mode, relates it to the given IO, binds the socket to the given endpoint and starts listening.

Inputs:
- endpoint: Where to bind the socket to
- backlog:  The maximum length to which the queue of pending connections may grow, before refusing connections
- l:        The event loop to associate the socket with, defaults to the current thread's loop

Returns:
- socket: The opened, bound and listening socket
- err:    A network error (`Create_Socket_Error`, `Bind_Error`, or `Listen_Error`) that has happened
*/
listen_tcp :: proc(endpoint: net.Endpoint, backlog := 1000, l: ^Event_Loop = nil, loc := #caller_location) -> (socket: TCP_Socket, err: net.Network_Error) {
	assert(backlog > 0 && backlog < int(max(i32)))
	return _listen_tcp(l if l != nil else _current_thread_event_loop(loc), endpoint, backlog)
}

File_Flags :: bit_set[File_Flag; int]
File_Flag :: enum {
	Read,
	Write,
	Append,
	Create,
	Excl,
	Sync,
	Trunc,
	Inheritable,
}

/*
Opens a file, sets non blocking mode and relates it to the given IO.

Inputs:
- mode: The open mode, defaults to read-only
- perm: The permissions to use when creating a file (on unix targets), defaults to group read, write execute
- l:    The event loop to associate the file with

Returns:
- handle: The file handle
- err:    An error if it occurred
*/
open :: proc(path: string, mode: File_Flags = {.Read}, perm: int = 0o777, l: ^Event_Loop = nil, loc := #caller_location) -> (handle: Handle, err: FS_Error) {
	return _open(l if l != nil else _current_thread_event_loop(loc), path, mode, perm)
}

/*
Execute an operation.
*/
exec :: proc(op: ^Operation) {
	if op.l == &_tls_event_loop {
		_exec(op)
	} else {
		ok := chan.send(op.l.queue, op)
		assert(ok, "channel is closed?")
	}
}
