#+private
package nbio

import "base:runtime"
import "base:intrinsics"

import "core:time"

IO :: struct {
	using impl:  _IO,
	err:         General_Error,
	refs:        int,
}

IDLE_TIME :: time.Millisecond

@(thread_local)
g_io: IO

_init :: proc() -> General_Error {
	io := &g_io
	if io.err == nil && io.refs == 0 {
		io.err = __init(io, runtime.heap_allocator())
	}

	if io.err != nil {
		return io.err
	}

	io.refs += 1
	return nil
}

_destroy :: proc() {
	io := &g_io
	if io.err != nil {
		assert(io.refs == 0)
		return
	}

	if io.refs > 0 {
		io.refs -= 1
		if io.refs == 0 {
			__destroy(io)
			io^ = {}
		}
	}
}

io :: #force_inline proc(loc := #caller_location) -> (io: ^IO) {
	io = &g_io

	if intrinsics.expect(io.refs == 0, false) {
		panic("nbio: thread's IO instance not initialized, did you forget to call nbio.init()?", loc)
	}

	return
}
