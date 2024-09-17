//+private
package nbio

import "base:runtime"
import "base:intrinsics"

import "core:os"

IO :: struct {
	using impl:  _IO,
	initialized: bool,
}

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
				// TODO: error message.
				panic("could not initialize non-blocking IO")
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

init :: proc(io: ^IO, allocator := context.allocator) -> (err: os.Errno) {
	return _init(io, allocator)
}

destroy :: proc(io: ^IO) {
	_destroy(io)
}
