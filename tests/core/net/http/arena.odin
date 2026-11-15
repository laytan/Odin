package test_core_net_http

import "base:runtime"

import "core:mem"
import "core:mem/virtual"
import "core:testing"

import http "core:http2"

@(test)
test_arena_reuses_non_power_of_two_block :: proc(t: ^testing.T) {
	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td

	a1 := http.get_arena(nil)
	bs1, alloc_err1 := http.arena_alloc(&a1, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, alloc_err1, nil)
	testing.expect_value(t, len(bs1), 5000)
	testing.expect(t, a1.tail != nil, "expected arena block to be allocated")
	testing.expect_value(t, len(a1.tail.data), 8192)

	first_block := a1.tail
	used_after_first := s.temp_allocator_backing.total_used

	http.arena_destroy(&a1)
	testing.expect(t, thread.free_arenas[1] == first_block, "expected 8 KiB block in bucket 1 freelist")
	testing.expect(t, thread.free_arenas[0] == nil, "expected bucket 0 freelist to remain empty")

	a2 := http.get_arena(nil)
	bs2, alloc_err2 := http.arena_alloc(&a2, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, alloc_err2, nil)
	testing.expect_value(t, len(bs2), 5000)
	testing.expect(t, a2.tail == first_block, "expected bucket 1 block to be reused")
	testing.expect_value(t, s.temp_allocator_backing.total_used, used_after_first)
	testing.expect(t, thread.free_arenas[1] == nil, "expected bucket 1 freelist to be empty after reuse")

	http.arena_destroy(&a2)
}

@(test)
test_arena_resize_and_free :: proc(t: ^testing.T) {
	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td

	a := http.get_arena(nil)
	defer http.arena_destroy(&a)

	alloc := http.arena_allocator(&a)
	buf, alloc_err := mem.alloc_bytes(64, mem.DEFAULT_ALIGNMENT, alloc)
	testing.expect_value(t, alloc_err, nil)
	for &b, i in buf {
		b = u8(i + 1)
	}

	resized, resize_err := mem.resize_bytes(buf, 128, mem.DEFAULT_ALIGNMENT, alloc)
	testing.expect_value(t, resize_err, nil)
	testing.expect(t, raw_data(resized) == raw_data(buf), "expected in-place resize")
	for i in 0..<64 {
		testing.expect_value(t, resized[i], u8(i + 1))
	}
	for i in 64..<128 {
		testing.expect_value(t, resized[i], u8(0))
	}

	free_err := mem.free_with_size(raw_data(resized), len(resized), alloc)
	testing.expect_value(t, free_err, nil)

	next_buf, next_err := mem.alloc_bytes(64, mem.DEFAULT_ALIGNMENT, alloc)
	testing.expect_value(t, next_err, nil)
	testing.expect(t, raw_data(next_buf) == raw_data(resized), "expected freed tail slot to be reused")

	no_free_all_alloc := http._arena_allocator(&a, false)
	_, free_all_err := no_free_all_alloc.procedure(no_free_all_alloc.data, .Free_All, 0, 0, nil, 0, #location())
	testing.expect_value(t, free_all_err, mem.Allocator_Error.Mode_Not_Implemented)
}

when size_of(uintptr) == 8 {
	@(test)
	test_arena_largest_bucket_freelist :: proc(t: ^testing.T) {
		s: http.Server
		err := virtual.arena_init_growing(&s.temp_allocator_backing, runtime.Gigabyte)
		testing.expect_value(t, err, nil)
		defer virtual.arena_destroy(&s.temp_allocator_backing)

		thread := http.Server_Thread{s = &s}
		prev_td := http.td
		http.td = &thread
		defer http.td = prev_td

		last_bucket := len(thread.free_arenas) - 1

		small := http._server_thread_get_free_arena(256 * mem.Megabyte)
		large := http._server_thread_get_free_arena(256 * mem.Megabyte + 4096)

		// Push large then small so freelist order is: small -> large -> nil.
		http._server_thread_put_free_arena(large)
		http._server_thread_put_free_arena(small)
		testing.expect(t, thread.free_arenas[last_bucket] == small, "expected small block at head")
		testing.expect(t, small.prev == large, "expected large block as small.prev")

		// Requesting a size > small and <= large must skip small and return large while keeping small in freelist.
		got_large := http._server_thread_get_free_arena(256 * mem.Megabyte + 4096)
		testing.expect(t, got_large == large, "expected large block to be matched from .prev")
		testing.expect(t, thread.free_arenas[last_bucket] == small, "expected small block to remain in freelist")

		// Push large back: freelist is now large -> small -> nil.
		http._server_thread_put_free_arena(got_large)
		testing.expect(t, thread.free_arenas[last_bucket] == large, "expected large block at head")

		// Requesting <= large must pop large from head and preserve small in freelist.
		got_head := http._server_thread_get_free_arena(256 * mem.Megabyte)
		testing.expect(t, got_head == large, "expected head block to be returned when len(data) >= size")
		testing.expect(t, thread.free_arenas[last_bucket] == small, "expected remaining freelist tail to be preserved")

		http._server_thread_put_free_arena(got_head)
	}
}
