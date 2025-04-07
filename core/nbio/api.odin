package nbio

import "base:intrinsics"

import "core:net"
import "core:time"

/*
Initialize or increment the reference counter for the current thread's nbio instance.
*/
init :: proc() -> General_Error {
	return _init()
}

/*
Destroy or decrease the reference counter for the current thread's nbio instance.
*/
destroy :: proc() {
	_destroy()
}

/*
Each time you call this the IO implementation checks its state
and calls any callbacks which are ready. You would typically call this in a loop.

Blocks for up-to 10ms waiting for events if there is nothing to do.

Inputs:
- io: The IO instance to tick

Returns:
- err: An error code when something went when retrieving events, 0 otherwise
*/
tick :: proc() -> General_Error {
	if g_io.refs == 0 { return nil }
	return _tick(&g_io)
}

run :: proc() -> General_Error {
	if g_io.refs == 0 { return nil }

	init()
	defer destroy()

	for _num_waiting(&g_io) > 0 {
		if errno := _tick(&g_io); errno != nil {
			return errno
		}
	}
	return nil
}

run_until :: proc(done: ^bool) -> General_Error {
	if g_io.refs == 0 { return nil }

	init()
	defer destroy()

	for _num_waiting(&g_io) > 0 && !intrinsics.volatile_load(done) {
		if errno := _tick(&g_io); errno != nil {
			return errno
		}
	}
	return nil
}

/*
Returns the number of in-progress IO to be completed.
*/
num_waiting :: proc() -> int {
	if g_io.refs == 0 { return 0 }
	return _num_waiting(&g_io)
}

/*
Returns the current time (of the last tick).
*/
now :: proc() -> time.Time {
	if g_io.refs == 0 { return time.now() }
	return _now(&g_io)
}

On_Timeout :: #type proc(user: rawptr)

/*
Schedules a callback to be called after the given duration elapses.

The accuracy depends on the time between calls to `tick`.
When you call it in a loop with no blocks or very expensive calculations in other scheduled event callbacks
it is reliable to about a ms of difference (so timeout of 10ms would almost always be ran between 10ms and 11ms).

NOTE: polymorphic variants for type safe user data are available under `timeout_poly`, `timeout_poly2`, and `timeout_poly3`.

Inputs:
- io:       The IO instance to use
- dur:      The minimum duration to wait before calling the given callback
*/
timeout :: proc(dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	return _timeout(io(), dur, user, callback)
}

On_Next_Tick :: #type proc(user: rawptr)

/*
Schedules a callback to be called during the next tick of the event loop.

NOTE: polymorphic variants for type safe user data are available under `next_tick_poly`, `next_tick_poly2`, and `next_tick_poly3`.

Inputs:
- io:   The IO instance to use
*/
next_tick :: proc(user: rawptr, callback: On_Next_Tick) -> ^Completion {
	return _next_tick(io(), user, callback)
}

/*
Removes the given target from the event loop.

Common use would be to cancel a timeout, remove a polling, or remove an `accept` before calling `close` on it's socket.
*/
remove :: proc(target: ^Completion) {
	if target == nil {
		return
	}

	_remove(io(), target)
}

// TODO: document.
// TODO: enforce target being the last added completion. You can only timeout the previously added completion.
// Maybe even not take a target at all.
with_timeout :: proc(dur: time.Duration, target: ^Completion, loc := #caller_location) -> ^Completion {
	if target == nil || dur == 0 { return nil }
	return _timeout_completion(io(), dur, target)
}

/*
Creates a socket, sets non blocking mode and relates it to the given IO

Inputs:
- io:       The IO instance to initialize the socket on/with
- family:   Should this be an IP4 or IP6 socket
- protocol: The type of socket (TCP or UDP)

Returns:
- socket: The opened socket
- err:    A network error (`Create_Socket_Error`, or `Set_Blocking_Error`) which happened while opening
*/
open_socket :: proc(
	family: net.Address_Family,
	protocol: net.Socket_Protocol,
) -> (
	socket: net.Any_Socket,
	err: net.Network_Error,
) {
	return _open_socket(io(), family, protocol)
}

/*
Creates a socket, sets non blocking mode, relates it to the given IO, binds the socket to the given endpoint and starts listening

Inputs:
- io:       The IO instance to initialize the socket on/with
- endpoint: Where to bind the socket to

Returns:
- socket: The opened, bound and listening socket
- err:    A network error that happened while opening
*/
open_and_listen_tcp :: proc(ep: net.Endpoint) -> (socket: net.TCP_Socket, err: net.Network_Error) {
	io := io()
	family := net.family_from_endpoint(ep)
	sock := _open_socket(io, family, .TCP) or_return
	socket = sock.(net.TCP_Socket)

	// TODO: bind has a io_uring operation, should it be used?

	if err = net.bind(socket, ep); err != nil {
		_close(io, socket, nil, empty_on_close)
		return
	}

	if err = _listen(socket); err != nil {
		_close(io, socket, nil, empty_on_close)
	}
	return
}

/*
Starts listening on the given socket

Inputs:
- socket:  The socket to start listening
- backlog: The amount of events to keep in the backlog when they are not consumed

Returns:
- err: A network error that happened when starting listening
*/
listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> (err: net.Listen_Error) {
	return _listen(socket, backlog)
}

File_Flags :: distinct bit_set[File_Flag; int]
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
Opens a file hande, sets non blocking mode and relates it to the given IO

*The perm argument is only used when on the darwin or linux platforms, when on Windows you can't use the os.S_\* constants because they aren't declared*
*To prevent compilation errors on Windows, you should use a `when` statement around using those constants and just pass 0*

Inputs:
- io:   The IO instance to connect the opened file to
- mode: The file mode                                 (default: os.O_RDONLY)
- perm: The permissions to use when creating a file   (default: 0)

Returns:
- handle: The file handle
- err:    The error code when an error occured, 0 otherwise
*/
open :: proc(path: string, mode: File_Flags = {.Read}, perm: int = 0o777) -> (handle: Handle, err: FS_Error) {
	return _open(io(), path, mode, perm)
}

/*
Returns the current file size of the handle in bytes.

Returns:
- size: The size of the file in bytes
- err:  The error when an error occured, 0 otherwise
*/
file_size :: proc(fd: Handle) -> (size: i64, err: FS_Error) {
	return _file_size(io(), fd)
}

/*
A union of types that are `close`'able by this package
*/
Closable :: union #no_nil {
	net.TCP_Socket,
	net.UDP_Socket,
	net.Socket,
	Handle,
}

On_Close :: #type proc(user: rawptr, err: FS_Error)

@private
empty_on_close :: proc(_: rawptr, _: FS_Error) {}

/*
Closes the given `Closable` socket or file handle that was originally created by this package.

NOTE: polymorphic variants for type safe user data are available under `close_poly`, `close_poly2`, and `close_poly3`.

Inputs:
- io: The IO instance to use
- fd: The `Closable` socket or handle (created using/by this package) to close
*/
close :: proc(fd: Closable, user: rawptr = nil, callback: On_Close = empty_on_close) -> (res: ^Completion) {
	res = _close(io(), fd, user, callback)
	if res == nil {
		callback(user, .Unsupported)
	}
	return
}

On_Accept :: #type proc(user: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error)

/*
Using the given socket, accepts the next incoming connection, calling the callback when that happens

NOTE: polymorphic variants for type safe user data are available under `accept_poly`, `accept_poly2`, and `accept_poly3`.

Inputs:
- io:     The IO instance to use
- socket: A bound and listening socket *that was created using this package*
*/
accept :: proc(socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> (res: ^Completion) {
	res = _accept(io(), socket, user, callback)
	if res == nil {
		callback(user, {}, {}, .Network_Unreachable)
	}
	return
}

On_Dial :: #type proc(user: rawptr, socket: net.TCP_Socket, err: net.Network_Error)

/*
Connects to the given endpoint, calling the given callback once it has been done

NOTE: polymorphic variants for type safe user data are available under `connect_poly`, `connect_poly2`, and `connect_poly3`.

Inputs:
- io:       The IO instance to use
- endpoint: An endpoint to connect a socket to
*/
dial :: proc(endpoint: net.Endpoint, user: rawptr, callback: On_Dial) -> ^Completion {
	completion, err := _dial(io(), endpoint, user, callback)
	if err != nil {
		callback(user, {}, err)
	}
	return completion
}

On_Recv_TCP :: #type proc(user: rawptr, received: int, err: net.TCP_Recv_Error)
On_Recv_UDP :: #type proc(user: rawptr, received: int, udp_client: net.Endpoint, err: net.UDP_Recv_Error)
On_Recv :: union {
	On_Recv_TCP,
	On_Recv_UDP,
}

/*
Receives from the given socket, at most `len(buf)` bytes, and calls the given callback

NOTE: polymorphic variants for type safe user data are available under `recv_poly`, `recv_poly2`, and `recv_poly3`.

Inputs:
- io:     The IO instance to use
- socket: Either a `net.TCP_Socket` or a `net.UDP_Socket` (that was opened/returned by this package) to receive from
- buf:    The buffer to put received bytes into
*/
recv_tcp :: proc(socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Recv_TCP) -> (res: ^Completion) {
	res = _recv(io(), socket, buf, user, callback)
	if res == nil {
		callback(user, 0, .Network_Unreachable)
	}
	return
}

recv_udp :: proc(socket: net.UDP_Socket, buf: []byte, user: rawptr, callback: On_Recv_UDP) -> (res: ^Completion) {
	res = _recv(io(), socket, buf, user, callback)
	if res == nil {
		callback(user, 0, {}, .Network_Unreachable)
	}
	return
}

/*
Receives from the given socket until the given buf is full or an error occurred, and calls the given callback

NOTE: polymorphic variants for type safe user data are available under `recv_all_poly`, `recv_all_poly2`, and `recv_all_poly3`.

Inputs:
- io:     The IO instance to use
- socket: Either a `net.TCP_Socket` or a `net.UDP_Socket` (that was opened/returned by this package) to receive from
- buf:    The buffer to put received bytes into
*/
recv_all_tcp :: proc(socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Recv_TCP) -> (res: ^Completion) {
	res = _recv(io(), socket, buf, user, callback, all = true)
	if res == nil {
		callback(user, 0, .Network_Unreachable)
	}
	return
}

recv_all_udp :: proc(socket: net.UDP_Socket, buf: []byte, user: rawptr, callback: On_Recv_UDP) -> (res: ^Completion) {
	res = _recv(io(), socket, buf, user, callback, all = true)
	if res == nil {
		callback(user, 0, {}, .Network_Unreachable)
	}
	return
}

On_Sent_TCP :: #type proc(user: rawptr, sent: int, err: net.TCP_Send_Error)
On_Sent_UDP :: #type proc(user: rawptr, sent: int, err: net.UDP_Send_Error)
On_Sent :: union {
	On_Sent_TCP,
	On_Sent_UDP,
}

/*
Sends at most `len(buf)` bytes from the given buffer over the socket connection, and calls the given callback

NOTE: polymorphic variants for type safe user data are available under `send_tcp_poly`, `send_tcp_poly2`, and `send_tcp_poly3`.

Inputs:
- io:       The IO instance to use
- socket:   a `net.TCP_Socket` to send to
- buf:      The buffer send
*/
send_tcp :: proc(socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Sent_TCP) -> (res: ^Completion) {
	res = _send(io(), socket, buf, user, callback)
	if res == nil {
		callback(user, 0, .Network_Unreachable)
	}
	return
}

/*
Sends at most `len(buf)` bytes from the given buffer to the given UDP socket, and calls the given callback

NOTE: polymorphic variants for type safe user data are available under `send_udp_poly`, `send_udp_poly2`, and `send_udp_poly3`.

Inputs:
- io:       The IO instance to use
- socket:   a `net.UDP_Socket` to send to
- buf:      The buffer send
*/
send_udp :: proc(
	io: ^IO,
	endpoint: net.Endpoint,
	socket: net.UDP_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent_UDP,
) -> (res: ^Completion) {
	res = _send(io, socket, buf, user, callback, endpoint)
	if res == nil {
		callback(user, 0, .Network_Unreachable)
	}
	return
}

/*
Sends the bytes from the given buffer over the socket connection, and calls the given callback

This will keep sending until either an error or the full buffer is sent

NOTE: polymorphic variants for type safe user data are available under `send_all_tcp_poly`, `send_all_tcp_poly2`, and `send_all_tcp_poly3`.
*/
send_all_tcp :: proc(socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Sent_TCP) -> (res: ^Completion) {
	res = _send(io(), socket, buf, user, callback, all = true)
	if res == nil {
		callback(user, 0, .Network_Unreachable)
	}
	return
}

/*
Sends the bytes from the given buffer to the given UDP socket, and calls the given callback

This will keep sending until either an error or the full buffer is sent

NOTE: polymorphic variants for type safe user data are available under `send_all_udp_poly`, `send_all_udp_poly2`, and `send_all_udp_poly3`.
*/
send_all_udp :: proc(
	io: ^IO,
	endpoint: net.Endpoint,
	socket: net.UDP_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent_UDP,
) -> (res: ^Completion) {
	res = _send(io, socket, buf, user, callback, endpoint, all = true)
	if res == nil {
		callback(user, 0, .Network_Unreachable)
	}
	return
}

On_Read :: #type proc(user: rawptr, read: int, err: FS_Error)

/*
Reads from the given handle, at the given offset, at most `len(buf)` bytes, and calls the given callback

NOTE: polymorphic variants for type safe user data are available under `read_at_poly`, `read_at_poly2`, and `read_at_poly3`.

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- offset:   The offset to begin the read from
- buf:      The buffer to put read bytes into
*/
read_at :: proc(fd: Handle, offset: int, buf: []byte, user: rawptr, callback: On_Read) -> (res: ^Completion) {
	res = _read(io(), fd, offset, buf, user, callback)
	if res == nil {
		callback(user, 0, .Unsupported)
	}
	return
}

/*
Reads from the given handle, at the given offset, until the given buf is full or an error occurred, and calls the given callback

NOTE: polymorphic variants for type safe user data are available under `read_at_all_poly`, `read_at_all_poly2`, and `read_at_all_poly3`.

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- offset:   The offset to begin the read from
- buf:      The buffer to put read bytes into
*/
read_at_all :: proc(fd: Handle, offset: int, buf: []byte, user: rawptr, callback: On_Read) -> (res: ^Completion) {
	res = _read(io(), fd, offset, buf, user, callback, all = true)
	if res == nil {
		callback(user, 0, .Unsupported)
	}
	return
}

On_Write :: #type proc(user: rawptr, written: int, err: FS_Error)

/*
Writes to the given handle, at the given offset, at most `len(buf)` bytes, and calls the given callback

NOTE: polymorphic variants for type safe user data are available under `write_at_poly`, `write_at_poly2`, and `write_at_poly3`.

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to write to from
- offset:   The offset to begin the write from
- buf:      The buffer to write to the file
*/
write_at :: proc(fd: Handle, offset: int, buf: []byte, user: rawptr, callback: On_Write) -> (res: ^Completion) {
	res = _write(io(), fd, offset, buf, user, callback)
	if res == nil {
		callback(user, 0, .Unsupported)
	}
	return
}

/*
Writes the given buffer to the given handle, at the given offset, and calls the given callback

This keeps writing until either an error or the full buffer being written

NOTE: polymorphic variants for type safe user data are available under `write_at_all_poly`, `write_at_all_poly2`, and `write_at_all_poly3`.

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to write to from
- offset:   The offset to begin the write from
- buf:      The buffer to write to the file
*/
write_at_all :: proc(fd: Handle, offset: int, buf: []byte, user: rawptr, callback: On_Write) -> (res: ^Completion) {
	res = _write(io(), fd, offset, buf, user, callback, true)
	if res == nil {
		callback(user, 0, .Unsupported)
	}
	return
}

// TODO: should this have an error too?
On_Poll :: #type proc(user: rawptr, event: Poll_Event)

/*
Polls for the given event on the subject handle

NOTE: polymorphic variants for type safe user data are available under `poll_poly`, `poll_poly2`, and `poll_poly3`.

TODO: make this accept sockets too.

Inputs:
- io:       The IO instance to use
- fd:       The file descriptor to poll
- event:    Whether to call the callback when `fd` is ready to be read from, or be written to
- multi:    Keeps the poll after an event happens, calling the callback again for further events, remove poll with `remove`
*/
poll :: proc(fd: Handle, event: Poll_Event, multi: bool, user: rawptr, callback: On_Poll) -> (res: ^Completion) {
	res = _poll(io(), fd, event, multi, user, callback)
	if res == nil {
		callback(user, nil)
	}
	return
}

Poll_Event :: enum {
	// The subject is ready to be read from.
	Read,
	// The subject is ready to be written to.
	Write,
}

Handle :: _Handle

// TODO: should this be configurable, with a minimum of course for the use of core?
MAX_USER_ARGUMENTS :: 5

Completion :: struct {
	// Implementation specifics, don't use outside of implementation/os.
	using _:   _Completion,

	user_data: rawptr,

	// Callback pointer and user args passed in poly variants.
	user_args: [MAX_USER_ARGUMENTS + 1]rawptr,
}
