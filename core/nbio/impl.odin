#+private
package nbio

import "base:runtime"
import "base:intrinsics"

import "core:container/pool"
import "core:sync/chan"

@(thread_local)
_tls_event_loop: Event_Loop

_acquire_thread_event_loop :: proc() -> General_Error {
	l := &_tls_event_loop
	if l.err == nil && l.refs == 0 {
		// TODO: Might not be the best data structure for this, it's full of locks?
		// WARN: this is saying that other threads can queue up to 64 operations without blocking until we receive them, is that enough?
		queue, queue_err := chan.create_buffered(chan.Chan(^Operation), 64, runtime.heap_allocator())
		if queue_err != nil {
			l.err = .Allocation_Failed
			return l.err
		}
		defer if l.err != nil { chan.destroy(&l.queue) }
		l.queue = queue

		if pool_err := pool.init(&l.operation_pool, "_pool_link"); pool_err != nil {
			l.err = .Allocation_Failed
			return l.err
		}
		defer if l.err != nil { pool.destroy(&l.operation_pool) }

		l.err = _init(l, runtime.heap_allocator())
	}

	if l.err != nil {
		return l.err
	}

	l.refs += 1
	return nil
}

_release_thread_event_loop :: proc() {
	l := &_tls_event_loop
	if l.err != nil {
		assert(l.refs == 0)
		return
	}

	if l.refs > 0 {
		l.refs -= 1
		if l.refs == 0 {
			chan.destroy(&l.queue)
			pool.destroy(&l.operation_pool)
			_destroy(l)
			l^ = {}
		}
	}
}

_current_thread_event_loop :: #force_inline proc(loc := #caller_location) -> (l: ^Event_Loop) {
	l = &_tls_event_loop

	if intrinsics.expect(l.refs == 0, false) {
		panic("nbio: thread's event loop instance not initialized, did you forget to call nbio.acquire_thread_event_loop() or forget to pass an existing thread's event loop?", loc)
	}

	return
}

_tick :: proc(l: ^Event_Loop) -> (err: General_Error) {
	// Receive operations queued from other threads first.
	for op in chan.try_recv(l.queue) {
		_exec(op)
	}

	return __tick(l)
}
