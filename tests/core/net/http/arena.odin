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
	defer http._server_thread_free_arenas_destroy(&thread)

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
	defer http._server_thread_free_arenas_destroy(&thread)

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
		defer http._server_thread_free_arenas_destroy(&thread)

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

@(test)
test_bootstrap_arena_destroy :: proc(t: ^testing.T) {
	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	a := http.bootstrap_arena(nil)
	testing.expect(t, a != nil && a.tail != nil, "expected bootstrapped arena and initial block")

	alloc := http.arena_allocator(a)
	small, small_err := mem.alloc_bytes(64, mem.DEFAULT_ALIGNMENT, alloc)
	testing.expect_value(t, small_err, nil)
	testing.expect_value(t, len(small), 64)

	large, large_err := mem.alloc_bytes(5000, mem.DEFAULT_ALIGNMENT, alloc)
	testing.expect_value(t, large_err, nil)
	testing.expect_value(t, len(large), 5000)

	http.arena_destroy(a)
	testing.expect(t, thread.free_arenas[0] != nil, "expected initial 4 KiB block in bucket 0 freelist")
	testing.expect(t, thread.free_arenas[1] != nil, "expected overflow 8 KiB block in bucket 1 freelist")
}

@(test)
test_arena_resize_shrink_and_aliasing :: proc(t: ^testing.T) {
	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	// 1. Non-tail shrink with stricter alignment forcing a new block.
	{
		a := http.get_arena(nil)
		defer http.arena_destroy(&a)

		_, pad_err := http.arena_alloc(&a, 1, 1)
		testing.expect_value(t, pad_err, nil)

		p1, p1_err := http.arena_alloc(&a, 256, 1)
		testing.expect_value(t, p1_err, nil)
		testing.expect(t, !mem.is_aligned(raw_data(p1), 64), "expected p1 to start unaligned for 64")
		for &b, i in p1 {
			b = u8(i)
		}

		p2, p2_err := http.arena_alloc(&a, 3750, 1)
		testing.expect_value(t, p2_err, nil)
		for &b in p2 {
			b = 0xAA
		}

		first_tail := a.tail
		shrunk, serr := http.arena_resize(&a, p1, 64, 64, should_zero = true)
		testing.expect_value(t, serr, nil)
		testing.expect_value(t, len(shrunk), 64)
		testing.expect(t, a.tail != first_tail, "expected non-tail stricter-aligned shrink to push a new block")
		testing.expect(t, mem.is_aligned(raw_data(shrunk), 64), "expected shrunk slice to be 64-byte aligned")
		for i in 0..<64 {
			testing.expect_value(t, shrunk[i], u8(i))
		}
		for b in p2 {
			testing.expect_value(t, b, u8(0xAA))
		}
	}

	// 2. Non-tail same-size resize and shrink do not clobber arena.last.
	{
		a := http.get_arena(nil)
		defer http.arena_destroy(&a)

		b1, b1_err := http.arena_alloc(&a, 64, 8)
		testing.expect_value(t, b1_err, nil)
		for &b in b1 {
			b = 0x11
		}

		b2, b2_err := http.arena_alloc(&a, 64, 8)
		testing.expect_value(t, b2_err, nil)
		for &b in b2 {
			b = 0x22
		}

		same, same_err := http.arena_resize(&a, b1, 64, 8)
		testing.expect_value(t, same_err, nil)
		testing.expect(t, raw_data(same) == raw_data(b1), "expected non-tail same-size resize to return original pointer")
		testing.expect(t, a.tail.last == raw_data(b2), "expected non-tail same-size resize not to overwrite arena.last")

		grown, grow_err := http.arena_resize(&a, same, 128, 8)
		testing.expect_value(t, grow_err, nil)
		testing.expect(t, raw_data(grown) != raw_data(b1), "expected growing non-tail allocation to relocate instead of overwriting b2")
		for i in 0..<64 {
			testing.expect_value(t, grown[i], u8(0x11))
		}
		for i in 64..<128 {
			testing.expect_value(t, grown[i], u8(0))
		}
		for b in b2 {
			testing.expect_value(t, b, u8(0x22))
		}
		testing.expect(t, a.tail.last == raw_data(grown), "expected arena.last updated to new grown allocation")

		b2_small, b2_small_err := http.arena_resize(&a, b2, 32, 8)
		testing.expect_value(t, b2_small_err, nil)
		testing.expect(t, raw_data(b2_small) == raw_data(b2), "expected non-tail shrink to return prefix in place")
		testing.expect_value(t, len(b2_small), 32)
		testing.expect(t, a.tail.last == raw_data(grown), "expected non-tail shrink not to clobber arena.last")
	}

	// 3. Tail shrink reclaims offset and size == 0 delegates to arena_free.
	{
		a := http.get_arena(nil)
		defer http.arena_destroy(&a)

		t1, t1_err := http.arena_alloc(&a, 128, 8)
		testing.expect_value(t, t1_err, nil)

		t1_shrunk, shrink_err := http.arena_resize(&a, t1, 64, 8)
		testing.expect_value(t, shrink_err, nil)
		testing.expect(t, raw_data(t1_shrunk) == raw_data(t1), "expected tail shrink in place")
		testing.expect_value(t, len(t1_shrunk), 64)

		t2, t2_err := http.arena_alloc(&a, 64, 8)
		testing.expect_value(t, t2_err, nil)
		testing.expect_value(t, uintptr(raw_data(t2)), uintptr(raw_data(t1)) + 64)

		zero_nt, znt_err := http.arena_resize(&a, t1_shrunk, 0, 8)
		testing.expect_value(t, znt_err, mem.Allocator_Error.Mode_Not_Implemented)
		testing.expect(t, zero_nt == nil, "expected nil slice on size == 0 non-tail resize")
		testing.expect(t, a.tail.last == raw_data(t2), "expected arena.last unchanged after failed size == 0 free")

		zero_t, zt_err := http.arena_resize(&a, t2, 0, 8)
		testing.expect_value(t, zt_err, nil)
		testing.expect(t, zero_t == nil, "expected nil slice on size == 0 tail resize")

		t3, t3_err := http.arena_alloc(&a, 64, 8)
		testing.expect_value(t, t3_err, nil)
		testing.expect(t, raw_data(t3) == raw_data(t2), "expected reclaimed tail slot to be reused")
	}
}

@(test)
test_arena_high_alignment_reuse_and_block_alignment :: proc(t: ^testing.T) {
	misalign_next_block_data_start :: proc(t: ^testing.T, s: ^http.Server, target_align: int) {
		probe, perr := virtual.arena_alloc(&s.temp_allocator_backing, 1, 1)
		testing.expect_value(t, perr, nil)
		next_ptr := int(uintptr(raw_data(probe)) + 1)
		rem := ((next_ptr % target_align) + target_align) % target_align
		desired_rem := (target_align - size_of(http._Arena_Block) + align_of(http._Arena_Block)) % target_align
		pad := (desired_rem - rem + target_align) % target_align
		if pad > 0 {
			_, pad_err := virtual.arena_alloc(&s.temp_allocator_backing, uint(pad), 1)
			testing.expect_value(t, pad_err, nil)
		}
	}

	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	// 1. Pooled 4 KiB block with worst-case offset for align = 128.
	{
		misalign_next_block_data_start(t, &s, 128)

		a1 := http.get_arena(nil)
		init_bs, init_err := http.arena_alloc(&a1, 64, 8)
		testing.expect_value(t, init_err, nil)
		testing.expect_value(t, len(init_bs), 64)
		testing.expect_value(t, len(a1.tail.data), 4096)
		testing.expect_value(t, int(uintptr(&a1.tail.data[size_of(http._Arena_Block)]) % 128), align_of(http._Arena_Block))
		first_block := a1.tail
		http.arena_destroy(&a1)

		a2 := http.get_arena(nil)
		defer http.arena_destroy(&a2)
		bs, alloc_err := http.arena_alloc(&a2, 3968, 128)
		testing.expect_value(t, alloc_err, nil)
		testing.expect_value(t, len(bs), 3968)
		testing.expect(t, a2.tail != first_block, "expected pooled 4 KiB block not to be picked without room for alignment padding")
		testing.expect(t, mem.is_aligned(raw_data(bs), 128), "expected 128-byte aligned allocation")
	}

	// 2. Pooled 8 KiB block with worst-case offset for align = 4096.
	{
		http._server_thread_free_arenas_destroy(&thread)
		misalign_next_block_data_start(t, &s, 4096)

		a1 := http.get_arena(nil)
		init_bs, init_err := http.arena_alloc(&a1, 5000, 8)
		testing.expect_value(t, init_err, nil)
		testing.expect_value(t, len(init_bs), 5000)
		testing.expect_value(t, len(a1.tail.data), 8192)
		testing.expect_value(t, int(uintptr(&a1.tail.data[size_of(http._Arena_Block)]) % 4096), align_of(http._Arena_Block))
		first_block := a1.tail
		http.arena_destroy(&a1)

		a2 := http.get_arena(nil)
		defer http.arena_destroy(&a2)
		bs, alloc_err := http.arena_alloc(&a2, 4096, 4096)
		testing.expect_value(t, alloc_err, nil)
		testing.expect_value(t, len(bs), 4096)
		testing.expect(t, a2.tail != first_block, "expected pooled 8 KiB block not to be picked without room for alignment padding")
		testing.expect(t, mem.is_aligned(raw_data(bs), 4096), "expected 4096-byte aligned allocation")
	}

	// 3. align = 1 first allocation after unaligned offset in backing still yields aligned _Arena_Block.
	{
		http._server_thread_free_arenas_destroy(&thread)
		_, bump_err := virtual.arena_alloc(&s.temp_allocator_backing, 1, 1)
		testing.expect_value(t, bump_err, nil)

		a := http.get_arena(nil)
		defer http.arena_destroy(&a)
		bs, alloc_err := http.arena_alloc(&a, 32, 1)
		testing.expect_value(t, alloc_err, nil)
		testing.expect_value(t, len(bs), 32)
		testing.expect(t, mem.is_aligned(a.tail, align_of(http._Arena_Block)), "expected _Arena_Block header aligned to align_of(_Arena_Block)")
	}

	// 4. Zero/default/invalid argument edge cases.
	{
		a := http.get_arena(nil)
		defer http.arena_destroy(&a)

		zero_bs, zero_err := http.arena_alloc(&a, 0, 8)
		testing.expect_value(t, zero_err, nil)
		testing.expect(t, zero_bs == nil, "expected nil slice for 0-byte allocation")
		testing.expect(t, a.tail == nil, "expected no arena block pushed for 0-byte allocation")

		_, neg_err := http.arena_alloc(&a, -1, 8)
		testing.expect_value(t, neg_err, mem.Allocator_Error.Invalid_Argument)

		_, bad_align_err := http.arena_alloc(&a, 16, 3)
		testing.expect_value(t, bad_align_err, mem.Allocator_Error.Invalid_Argument)

		def_bs, def_err := http.arena_alloc(&a, 16, 0)
		testing.expect_value(t, def_err, nil)
		testing.expect_value(t, len(def_bs), 16)
		testing.expect(t, mem.is_aligned(raw_data(def_bs), mem.DEFAULT_ALIGNMENT), "expected align == 0 to use DEFAULT_ALIGNMENT")
	}
}

@(test)
test_arena_oom_propagation :: proc(t: ^testing.T) {
	backing_buf: [1024]byte
	s: http.Server
	err := virtual.arena_init_buffer(&s.temp_allocator_backing, backing_buf[:])
	testing.expect_value(t, err, nil)

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	blk, blk_err := http._server_thread_get_free_arena()
	testing.expect_value(t, blk_err, mem.Allocator_Error.Out_Of_Memory)
	testing.expect(t, blk == nil, "expected nil block when backing is exhausted")

	boot, boot_err := http.bootstrap_arena(nil)
	testing.expect_value(t, boot_err, mem.Allocator_Error.Out_Of_Memory)
	testing.expect(t, boot == nil, "expected nil arena from bootstrap_arena on OOM")

	a := http.get_arena(nil)
	bs, alloc_err := http.arena_alloc(&a, 64, 8)
	testing.expect_value(t, alloc_err, mem.Allocator_Error.Out_Of_Memory)
	testing.expect(t, bs == nil, "expected nil slice from arena_alloc on OOM")
	testing.expect(t, a.tail == nil, "expected tail to remain nil on OOM")

	rbs, resize_err := http.arena_resize(&a, nil, 64, 8)
	testing.expect_value(t, resize_err, mem.Allocator_Error.Out_Of_Memory)
	testing.expect(t, rbs == nil, "expected nil slice from arena_resize on OOM")
	testing.expect(t, a.tail == nil, "expected tail to remain nil on OOM")
}
