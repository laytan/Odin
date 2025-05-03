#+build !js
#+private
package nbio

import "base:runtime"

import "core:mem/virtual"

Pool_Arena :: virtual.Arena

pool_arena_init :: proc(p: ^Pool) -> (err: runtime.Allocator_Error) {
	virtual.arena_init_growing(&p.arena) or_return
	p.objects_allocator = virtual.arena_allocator(&p.arena)
	return
}
