#+private
package nbio

import "base:runtime"

Pool_Arena :: runtime.Arena

pool_arena_init :: proc(p: ^Pool) -> (err: runtime.Allocator_Error) {
	runtime.arena_init(&p.arena, 0, runtime.default_wasm_allocator()) or_return
	p.objects_allocator = runtime.arena_allocator(&p.arena)
	return
}
