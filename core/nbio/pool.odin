#+private
package nbio

import "base:sanitizer"

import "core:mem"
import "core:mem/virtual"
import "core:sync"

// TODO: remove, just for testing.
THREAD_SAFE      :: #config(NBIO_THREAD_SAFE_POOL, true)

POOL_INITIAL_CAP :: 8

// An object pool where the objects are allocated on a growing arena.
Pool :: struct #no_copy {
	arena:             Pool_Arena,
	objects_allocator: mem.Allocator,
	num_waiting:       int,
	head:              ^Completion,
}

@(require_results)
pool_init :: proc(p: ^Pool) -> (err: mem.Allocator_Error) {
	pool_arena_init(p) or_return

	for _ in 0..<POOL_INITIAL_CAP {
		completion := new(Completion, p.objects_allocator) or_else panic("nbio: object pool allocation error")
		pool_put(p, completion)
		p.num_waiting = 0
	}

	return nil
}

pool_destroy :: proc(p: ^Pool) {
	for elem := p.head; elem != nil; elem = elem.next {
		unpoison_completion(elem)
		free(elem, p.objects_allocator)
	}

	virtual.arena_destroy(&p.arena)
}

@(require_results)
pool_get :: proc(p: ^Pool) -> (completion: ^Completion) {
	when THREAD_SAFE {
		sync.atomic_add(&p.num_waiting, 1)

		for {
			completion = sync.atomic_load(&p.head)
			if completion == nil {
				// NOTE: virtual allocator has an internal lock.
				return new(Completion, p.objects_allocator) or_else panic("nbio: object pool allocation error")
			}

			if _, ok := sync.atomic_compare_exchange_weak(&p.head, completion, completion.next); ok {
				completion.next = nil
				unpoison_completion(completion)
				return
			}
		}
	} else {
		p.num_waiting += 1

		completion = p.head
		if completion == nil {
			return new(Completion, p.objects_allocator) or_else panic("nbio: object pool allocation error")
		}

		p.head = completion.next

		completion.next = nil
		unpoison_completion(completion)
		return
	}
}

pool_put :: proc(p: ^Pool, completion: ^Completion) {
	mem.zero_item(completion)
	poison_completion(completion)

	when THREAD_SAFE {
		defer sync.atomic_sub(&p.num_waiting, 1)

		for {
			head := sync.atomic_load(&p.head)
			completion.next = head
			if _, ok := sync.atomic_compare_exchange_weak(&p.head, head, completion); ok {
				return
			}
		}
	} else {
		p.num_waiting -= 1

		completion.next = p.head
		p.head = completion
	}
}

@(disabled=.Address not_in ODIN_SANITIZER_FLAGS)
poison_completion :: proc(completion: ^Completion) {
	#assert(offset_of(Completion, next) == 0)
	sanitizer.address_poison_rawptr(rawptr(uintptr(completion) + size_of(rawptr)), size_of(Completion) - size_of(rawptr))
}

@(disabled=.Address not_in ODIN_SANITIZER_FLAGS)
unpoison_completion :: proc(completion: ^Completion) {
	#assert(offset_of(Completion, next) == 0)
	sanitizer.address_unpoison_rawptr(rawptr(uintptr(completion) + size_of(rawptr)), size_of(Completion) - size_of(rawptr))
}
