#+private
package nbio

import "base:runtime"

import "core:time"

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

_init :: proc(io: ^IO, allocator := context.allocator) -> (err: General_Error) {
	io.allocator = allocator
	io.pending.allocator = allocator
	io.done.allocator = allocator
	io.free_list.allocator = allocator
	return nil
}

_num_waiting :: #force_inline proc(io: ^IO) -> int {
	return io.num_waiting
}

_destroy :: proc(io: ^IO) {
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

_timeout_completion :: proc(io: ^IO, dur: time.Duration, target: ^Completion) -> ^Completion {
	// NOTE: none of the operations we support for JS, are able to timeout on other targets.
	panic("trying to add a timeout to an operation that can't timeout")
}

_timeout_remove :: proc(io: ^IO, timeout: ^Completion) {
	// NOTE: none of the operations we support for JS, are able to timeout on other targets.
	panic("trying to add a timeout to an operation that can't timeout")
}

_remove :: proc(io: ^IO, target: ^Completion) {
	unimplemented()
}
