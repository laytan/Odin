#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+build !linux
#+build !windows
#+private
package nbio

import "core:net"
import "core:time"

when ODIN_OS == .JS {
	@(export)
	nbio_io_ptr :: proc() -> ^IO {
		return io()
	}

	@(export)
	nbio_tick :: proc() {
		err := _tick(io())
		if err != nil {
			buf: [1024]byte = ---
			n := copy(buf[:], "could not tick non-blocking IO: ")
			n += copy(buf[:], error_string(err))
			panic(string(buf[:n]))
		}
	}
}

__init :: proc(io: ^IO, allocator := context.allocator) -> (err: General_Error) {
	io.allocator = allocator
	io.pending.allocator = allocator
	io.done.allocator = allocator
	io.free_list.allocator = allocator
	return nil
}

_num_waiting :: #force_inline proc(io: ^IO) -> int {
	return io.num_waiting
}

__destroy :: proc(io: ^IO) {
	context.allocator = io.allocator
	for c in io.pending {
		free(c)
	}
	delete(io.pending)

	for c in io.done {
		free(c)
	}
	delete(io.done)

	for c in io.free_list {
		free(c)
	}
	delete(io.free_list)
}

_now :: proc(io: ^IO) -> time.Time {
	return io.now
}

_tick :: proc(io: ^IO) -> General_Error {
	io.now = time.now()

	if len(io.pending) > 0 {
		#reverse for c, i in io.pending {
			if time.diff(io.now, c.timeout) <= 0 {
				ordered_remove(&io.pending, i)

				_, err := append(&io.done, c)
				if err != nil { return .Allocation_Failed }
			}
		}
	}

	for {
		completion := pop_safe(&io.done) or_break
		context = completion.ctx
		completion.cb(completion.user_data)
		io.num_waiting -= 1

		_, err := append(&io.free_list, completion)
		if err != nil { return .Allocation_Failed }
	}

	return nil
}

_open_socket :: proc(_: ^IO, family: net.Address_Family, protocol: net.Socket_Protocol) -> (socket: net.Any_Socket, err: net.Network_Error) {
	return nil, net.Create_Socket_Error.Network_Unreachable
}

_prepare_socket :: proc(socket: net.Any_Socket) -> net.Set_Blocking_Error {
	return net.Set_Blocking_Error.Network_Unreachable
}

_open :: proc(_: ^IO, path: string, flags: File_Flags, perm: int) -> (handle: Handle, errno: FS_Error) {
	return 0, .Unsupported
}

_file_size :: proc(_: ^IO, fd: Handle) -> (i64, FS_Error) {
	return 0, .Unsupported
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Listen_Error {
	return .Network_Unreachable
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	return nil
}

_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) -> ^Completion {
	return nil
}

_dial :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Dial) -> (completion: ^Completion, err: net.Network_Error) {
	return nil, net.Dial_Error.Network_Unreachable
}

_read :: proc(io: ^IO, fd: Handle, offset: int, buf: []byte, user: rawptr, callback: On_Read, all := false) -> ^Completion {
	return nil
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv, all := false) -> ^Completion {
	return nil
}

_send :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Sent, endpoint: Maybe(net.Endpoint) = nil, all := false) -> ^Completion {
	return nil
}

_write :: proc(io: ^IO, fd: Handle, offset: int, buf: []byte, user: rawptr, callback: On_Write, all := false) -> ^Completion {
	return nil
}

// Runs the callback after the timeout, using the kqueue.
_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	completion, ok := pop_safe(&io.free_list)
	if !ok {
		completion = new_completion(io)
	}

	completion.ctx = context
	completion.user_data = user
	completion.cb = callback
	completion.timeout = time.time_add(io.now, dur)

	io.num_waiting += 1
	push_pending(io, completion)
	return completion
}

_timeout_completion :: proc(io: ^IO, dur: time.Duration, target: ^Completion) -> ^Completion {
	// NOTE: none of the operations we support are able to timeout on other targets.
	panic("trying to add a timeout to an operation that can't timeout")
}

_remove :: proc(io: ^IO, target: ^Completion) {
	// TODO: should be able to remove timeouts, (and next ticks?)
	unimplemented()
}

_next_tick :: proc(io: ^IO, user: rawptr, callback: On_Next_Tick) -> ^Completion {
	completion, ok := pop_safe(&io.free_list)
	if !ok {
		completion = new_completion(io)
	}

	completion.ctx = context
	completion.user_data = user
	completion.cb = callback

	io.num_waiting += 1
	push_done(io, completion)
	return completion
}

_poll :: proc(io: ^IO, fd: Handle, event: Poll_Event, multi: bool, user: rawptr, callback: On_Poll) -> ^Completion {
	return nil
}
