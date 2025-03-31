#+private
package nbio

import "base:runtime"
import "base:intrinsics"

import "core:time"

IO :: struct {
	using impl:  _IO,
	initialized: bool,
}

IDLE_TIME :: time.Millisecond

@(thread_local)
g_io: IO

@(init)
register_destroy_thread :: proc() {
	runtime.add_thread_local_cleaner(destroy_thread)
}

io :: #force_inline proc() -> (io: ^IO) {
	io = &g_io

	if !io.initialized {
		@(cold)
		internal :: proc(io: ^IO) {
			if err := init(io, runtime.heap_allocator()); err != nil {
				buf: [1024]byte = ---
				n := copy(buf[:], "could not initialize non-blocking IO: ")
				n += copy(buf[:], error_string(err))
				panic(string(buf[:n]))
			}
			io.initialized = true

		}
		internal(io)
	}

	return
}

destroy_thread :: proc() {
	if !g_io.initialized { return }
	destroy(&g_io)
}

init :: proc(io: ^IO, allocator := context.allocator) -> (err: General_Error) {
	assert(!io.initialized)
	return _init(io, allocator)
}

destroy :: proc(io: ^IO) {
	assert(io.initialized)
	_destroy(io)
}
