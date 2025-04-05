#+build windows, linux, darwin, freebsd
#+private
package nbio

import "base:runtime"

import "core:container/queue"
import "core:mem"
import "core:mem/virtual"

// TODO: this is a dumb thrown together pool, we should add a good one to `core` and use that.

// An object pool where the objects are allocated on a growing arena.
Pool :: struct #no_copy {
	arena:             virtual.Arena,
	objects_allocator: mem.Allocator,
	objects:           queue.Queue(^Completion),
	// waiting:           map[^T]struct{},
	num_waiting:       int,
}

@(require_results)
pool_init :: proc(p: ^Pool, cap := 8, allocator := context.allocator) -> (err: mem.Allocator_Error) {
	virtual.arena_init_growing(&p.arena) or_return
	defer if err != nil { virtual.arena_destroy(&p.arena) }

	p.objects_allocator = virtual.arena_allocator(&p.arena)

	queue.init(&p.objects, cap, allocator) or_return
	defer if err != nil {
		for elem in queue.pop_front_safe(&p.objects) {
			free(elem, p.objects_allocator)
		}
		queue.destroy(&p.objects)
	}

	for _ in 0 ..< cap {
		completion := new(Completion, p.objects_allocator) or_return

		ok, perr := queue.push_back(&p.objects, completion)
		assert(ok)
		assert(perr == nil)
	}

	return nil
}

pool_destroy :: proc(p: ^Pool) {
	for elem in queue.pop_front_safe(&p.objects) {
		free(elem, p.objects_allocator)
	}
	virtual.arena_destroy(&p.arena)
	queue.destroy(&p.objects)
}

@(require_results)
pool_get :: proc(p: ^Pool) -> (completion: ^Completion) {
	p.num_waiting += 1

	ok: bool
	completion, ok = queue.pop_front_safe(&p.objects)
	if !ok {
		err: runtime.Allocator_Error
		if completion, err = new(Completion, p.objects_allocator); err != nil {
			panic("nbio completion pool allocation error")
		}
	}

	return
}

pool_put :: proc(p: ^Pool, elem: ^Completion) {
	p.num_waiting -= 1
	assert(elem.operation != nil)
	mem.zero_item(elem)
	if _, err := queue.push_back(&p.objects, elem); err != nil {
		panic("nbio completion pool allocation error")
	}
	return
}
