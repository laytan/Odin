package test_core_net_http

import "base:runtime"

import "core:mem"
import "core:testing"

import http "core:http2"

Arena_Counting_Allocator :: struct {
	backing:     mem.Allocator,
	alloc_count: int,
	free_count:  int,
}

arena_counting_allocator :: proc(c: ^Arena_Counting_Allocator) -> mem.Allocator {
	return {
		data = c,
		procedure = proc(
			allocator_data: rawptr,
			mode: mem.Allocator_Mode,
			size, alignment: int,
			old_memory: rawptr,
			old_size: int,
			location := #caller_location,
		) -> ([]byte, mem.Allocator_Error) {
			c := (^Arena_Counting_Allocator)(allocator_data)
			#partial switch mode {
			case .Alloc, .Alloc_Non_Zeroed:
				c.alloc_count += 1
			case .Free:
				if old_memory != nil {
					c.free_count += 1
				}
			}
			return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, location)
		},
	}
}

@(test)
test_arena_reuses_non_power_of_two_block :: proc(t: ^testing.T) {
	counter := Arena_Counting_Allocator{backing = context.allocator}
	s := http.make_server({}, arena_counting_allocator(&counter))

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
	testing.expect_value(t, counter.alloc_count, 1)

	first_block := a1.tail

	http.arena_destroy(&a1)
	testing.expect(t, thread.free_arenas[1] == first_block, "expected 8 KiB block in bucket 1 freelist")
	testing.expect(t, thread.free_arenas[0] == nil, "expected bucket 0 freelist to remain empty")

	a2 := http.get_arena(nil)
	bs2, alloc_err2 := http.arena_alloc(&a2, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, alloc_err2, nil)
	testing.expect_value(t, len(bs2), 5000)
	testing.expect(t, a2.tail == first_block, "expected bucket 1 block to be reused")
	testing.expect_value(t, counter.alloc_count, 1)
	testing.expect(t, thread.free_arenas[1] == nil, "expected bucket 1 freelist to be empty after reuse")

	http.arena_destroy(&a2)
	http._server_thread_free_arenas_destroy(&thread)
	testing.expect_value(t, counter.free_count, counter.alloc_count)
}

@(test)
test_arena_resize_and_free :: proc(t: ^testing.T) {
	s := http.make_server({})

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

@(test)
test_arena_no_giant_block_stealing :: proc(t: ^testing.T) {
	s := http.make_server({})

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	a_big := http.get_arena(nil)
	big_bs, big_err := http.arena_alloc(&a_big, 50_000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, big_err, nil)
	testing.expect_value(t, len(big_bs), 50_000)
	big_block := a_big.tail
	testing.expect(t, big_block != nil, "expected big block to be allocated")
	testing.expect_value(t, len(big_block.data), 64 * mem.Kilobyte)

	http.arena_destroy(&a_big)
	testing.expect(t, thread.free_arenas[4] == big_block, "expected 64 KiB block cached in bucket 4")

	// Small 4 KiB request must NOT steal the cached 64 KiB block from bucket 4.
	a_small := http.get_arena(nil)
	defer http.arena_destroy(&a_small)
	small_bs, small_err := http.arena_alloc(&a_small, 64, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, small_err, nil)
	testing.expect_value(t, len(small_bs), 64)
	testing.expect(t, a_small.tail != big_block, "expected small request not to steal cached 64 KiB block")
	testing.expect_value(t, len(a_small.tail.data), 4096)
	testing.expect(t, thread.free_arenas[4] == big_block, "expected 64 KiB block to remain in bucket 4")
}

@(test)
test_arena_oversized_block_not_pooled :: proc(t: ^testing.T) {
	counter := Arena_Counting_Allocator{backing = context.allocator}
	s := http.make_server({}, arena_counting_allocator(&counter))

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	max_pooled := 16 * mem.Megabyte
	req_size := max_pooled + 4096
	a := http.get_arena(nil)
	bs, alloc_err := http.arena_alloc(&a, req_size, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, alloc_err, nil)
	testing.expect_value(t, len(bs), req_size)
	testing.expect(t, a.tail != nil, "expected oversized block to be allocated")
	testing.expect(t, len(a.tail.data) >= req_size + size_of(http._Arena_Block), "expected block to fit overhead + req_size")
	testing.expect(t, len(a.tail.data) < max_pooled * 2, "expected exact size allocation rather than 2x power-of-two rounding")
	testing.expect_value(t, counter.alloc_count, 1)

	http.arena_destroy(&a)
	for head in thread.free_arenas {
		testing.expect(t, head == nil, "expected oversized block not to be placed in free_arenas")
	}
	testing.expect_value(t, counter.free_count, 1)
}

@(test)
test_bootstrap_arena_destroy :: proc(t: ^testing.T) {
	s := http.make_server({})

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
	s := http.make_server({})

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
	misalign_next_block_data_start :: proc(t: ^testing.T, backing: ^mem.Arena, target_align: int) {
		probe, perr := mem.arena_alloc_bytes(backing, 1, 1)
		testing.expect_value(t, perr, nil)
		next_ptr := int(uintptr(raw_data(probe)) + 1)
		rem := ((next_ptr % target_align) + target_align) % target_align
		desired_rem := (target_align - size_of(http._Arena_Block) + align_of(http._Arena_Block)) % target_align
		pad := (desired_rem - rem + target_align) % target_align
		if pad > 0 {
			_, pad_err := mem.arena_alloc_bytes(backing, pad, 1)
			testing.expect_value(t, pad_err, nil)
		}
	}

	backing_buf, buf_err := make([]byte, 128 * mem.Kilobyte)
	testing.expect_value(t, buf_err, nil)
	defer delete(backing_buf)

	backing_arena: mem.Arena
	mem.arena_init(&backing_arena, backing_buf)

	s := http.make_server({}, mem.arena_allocator(&backing_arena))

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	// 1. Pooled 4 KiB block with worst-case offset for align = 128.
	{
		misalign_next_block_data_start(t, &backing_arena, 128)

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
		mem.arena_free_all(&backing_arena)
		misalign_next_block_data_start(t, &backing_arena, 4096)

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
		mem.arena_free_all(&backing_arena)
		_, bump_err := mem.arena_alloc_bytes(&backing_arena, 1, 1)
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
	backing_arena: mem.Arena
	mem.arena_init(&backing_arena, backing_buf[:])
	s := http.make_server({}, mem.arena_allocator(&backing_arena))

	thread := http.Server_Thread{s = &s}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	blk, blk_err := http._server_thread_get_free_arena()
	testing.expect_value(t, blk_err, mem.Allocator_Error.Out_Of_Memory)
	testing.expect(t, blk == nil, "expected nil block when backing is exhausted")

	ovf_blk, ovf_err := http._server_thread_get_free_arena(max(int))
	testing.expect_value(t, ovf_err, mem.Allocator_Error.Out_Of_Memory)
	testing.expect(t, ovf_blk == nil, "expected nil block on size overflow")

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
