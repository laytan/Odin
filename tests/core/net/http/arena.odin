package test_core_net_http

import "core:mem"
import "core:testing"
import "core:thread"

import http "core:http2"

@(test)
test_arena_reuses_non_power_of_two_block :: proc(t: ^testing.T) {
	counter := Test_Counting_Allocator{backing = context.allocator}
	env: Test_Env
	test_env_init(&env, allocator = test_counting_allocator(&counter))
	defer test_env_destroy(&env)

	a1 := http.get_arena(nil)
	bs1, alloc_err1 := http.arena_alloc(&a1, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, alloc_err1, nil)
	testing.expect_value(t, len(bs1), 5000)
	testing.expect(t, a1.tail != nil, "expected arena block to be allocated")
	testing.expect_value(t, len(a1.tail.data), 8192)
	testing.expect_value(t, counter.alloc_count, 1)

	first_block := a1.tail

	http.arena_destroy(&a1)
	testing.expect(t, env.thread.free_arenas[1].head == first_block, "expected 8 KiB block in bucket 1 freelist")
	testing.expect(t, env.thread.free_arenas[0].head == nil, "expected bucket 0 freelist to remain empty")

	a2 := http.get_arena(nil)
	bs2, alloc_err2 := http.arena_alloc(&a2, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, alloc_err2, nil)
	testing.expect_value(t, len(bs2), 5000)
	testing.expect(t, a2.tail == first_block, "expected bucket 1 block to be reused")
	testing.expect_value(t, counter.alloc_count, 1)
	testing.expect(t, env.thread.free_arenas[1].head == nil, "expected bucket 1 freelist to be empty after reuse")

	http.arena_destroy(&a2)
	http._server_thread_free_arenas_destroy(&env.thread)
	testing.expect_value(t, counter.free_count, counter.alloc_count)
}

@(test)
test_arena_resize_and_free :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

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
	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	a_big := http.get_arena(nil)
	big_bs, big_err := http.arena_alloc(&a_big, 50_000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, big_err, nil)
	testing.expect_value(t, len(big_bs), 50_000)
	big_block := a_big.tail
	testing.expect(t, big_block != nil, "expected big block to be allocated")
	testing.expect_value(t, len(big_block.data), 64 * mem.Kilobyte)

	http.arena_destroy(&a_big)
	testing.expect(t, env.thread.free_arenas[4].head == big_block, "expected 64 KiB block cached in bucket 4")

	// Small 4 KiB request must NOT steal the cached 64 KiB block from bucket 4.
	a_small := http.get_arena(nil)
	defer http.arena_destroy(&a_small)
	small_bs, small_err := http.arena_alloc(&a_small, 64, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, small_err, nil)
	testing.expect_value(t, len(small_bs), 64)
	testing.expect(t, a_small.tail != big_block, "expected small request not to steal cached 64 KiB block")
	testing.expect_value(t, len(a_small.tail.data), 4096)
	testing.expect(t, env.thread.free_arenas[4].head == big_block, "expected 64 KiB block to remain in bucket 4")
}

@(test)
test_arena_oversized_block_not_pooled :: proc(t: ^testing.T) {
	counter := Test_Counting_Allocator{backing = context.allocator}
	env: Test_Env
	test_env_init(&env, allocator = test_counting_allocator(&counter))
	defer test_env_destroy(&env)

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
	for b in env.thread.free_arenas {
		testing.expect(t, b.head == nil, "expected oversized block not to be placed in free_arenas")
	}
	testing.expect_value(t, counter.free_count, 1)
}

@(test)
test_bootstrap_arena_destroy :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

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
	testing.expect(t, env.thread.free_arenas[0].head != nil, "expected initial 4 KiB block in bucket 0 freelist")
	testing.expect(t, env.thread.free_arenas[1].head != nil, "expected overflow 8 KiB block in bucket 1 freelist")
}

@(test)
test_arena_resize_shrink_and_aliasing :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

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
		for &b in b1 { b = 0x11 }

		b2, b2_err := http.arena_alloc(&a, 64, 8)
		testing.expect_value(t, b2_err, nil)
		for &b in b2 { b = 0x22 }

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

	env: Test_Env
	test_env_init(&env, allocator = mem.arena_allocator(&backing_arena))
	defer test_env_destroy(&env)

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
		http._server_thread_free_arenas_destroy(&env.thread)
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
		http._server_thread_free_arenas_destroy(&env.thread)
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

	env: Test_Env
	test_env_init(&env, allocator = mem.arena_allocator(&backing_arena))
	defer test_env_destroy(&env)

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

@(test)
test_arena_cross_thread_worker_destroy :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	test_tracking_init(&track)
	defer mem.tracking_allocator_destroy(&track)

	counter := Test_Counting_Allocator{backing = mem.tracking_allocator(&track)}
	env: Test_Env
	test_env_init(&env, allocator = test_counting_allocator(&counter))
	defer test_env_destroy(&env)

	boot, boot_err := http.bootstrap_arena(nil)
	testing.expect_value(t, boot_err, nil)
	testing.expect(t, boot != nil, "expected bootstrapped arena")

	boot_small, bs_err := mem.alloc_bytes(64, mem.DEFAULT_ALIGNMENT, http.arena_allocator(boot))
	testing.expect_value(t, bs_err, nil)
	for &b in boot_small { b = 0xA1 }
	boot_large, bl_err := mem.alloc_bytes(5000, mem.DEFAULT_ALIGNMENT, http.arena_allocator(boot))
	testing.expect_value(t, bl_err, nil)
	for &b in boot_large { b = 0xB2 }

	val_arena := http.get_arena(nil)
	val_small, vs_err := http.arena_alloc(&val_arena, 64, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, vs_err, nil)
	for &b in val_small { b = 0xC3 }
	val_large, vl_err := http.arena_alloc(&val_arena, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, vl_err, nil)
	for &b in val_large { b = 0xD4 }

	testing.expect_value(t, counter.alloc_count, 4)

	Work :: struct {
		boot:        ^http.Arena,
		val_arena:   ^http.Arena,
		boot_small:  []byte,
		boot_large:  []byte,
		val_small:   []byte,
		val_large:   []byte,
		td_was_nil:  bool,
		bytes_valid: bool,
	}
	work := Work{
		boot       = boot,
		val_arena  = &val_arena,
		boot_small = boot_small,
		boot_large = boot_large,
		val_small  = val_small,
		val_large  = val_large,
	}

	w := thread.create_and_start_with_data(&work, proc(data: rawptr) {
		work := (^Work)(data)
		work.td_was_nil = http.td == nil

		valid := true
		for b in work.boot_small { if b != 0xA1 { valid = false } }
		for b in work.boot_large { if b != 0xB2 { valid = false } }
		for b in work.val_small  { if b != 0xC3 { valid = false } }
		for b in work.val_large  { if b != 0xD4 { valid = false } }
		work.bytes_valid = valid

		http.arena_destroy(work.boot)
		http.arena_destroy(work.val_arena)
		http.arena_destroy(nil)
	})
	testing.expect(t, w != nil, "expected worker thread created")
	thread.destroy(w)

	testing.expect(t, work.td_was_nil, "expected http.td to be nil on spawned worker thread")
	testing.expect(t, work.bytes_valid, "expected arena bytes intact across threads")
	testing.expect(t, val_arena.tail == nil, "expected val_arena.tail cleared after worker destroy")
	for b in env.thread.free_arenas {
		testing.expect(t, b.head == nil, "expected worker destroy not to push into server free_arenas")
	}
	testing.expect_value(t, counter.free_count, 4)
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
test_arena_cross_thread_worker_alloc_and_server_reclaim :: proc(t: ^testing.T) {
	server_track: mem.Tracking_Allocator
	test_tracking_init(&server_track)
	defer mem.tracking_allocator_destroy(&server_track)

	worker_track: mem.Tracking_Allocator
	test_tracking_init(&worker_track)
	defer mem.tracking_allocator_destroy(&worker_track)

	env: Test_Env
	test_env_init(&env, allocator = mem.tracking_allocator(&server_track))
	defer test_env_destroy(&env)

	a := http.get_arena(nil)

	Work :: struct {
		arena:         ^http.Arena,
		server_track:  ^mem.Tracking_Allocator,
		worker_alloc:  mem.Allocator,
		td_was_nil:    bool,
		ok:            bool,
		boot_backed:   bool,
		worker_unused: bool,
	}
	work := Work{
		arena        = &a,
		server_track = &server_track,
		worker_alloc = mem.tracking_allocator(&worker_track),
	}

	w := thread.create_and_start_with_data(&work, proc(data: rawptr) {
		work := (^Work)(data)
		work.td_was_nil = http.td == nil
		context.allocator = work.worker_alloc

		b1, e1 := http.arena_alloc(work.arena, 2000, mem.DEFAULT_ALIGNMENT)
		if e1 != nil || len(b1) != 2000 { return }
		for &b in b1 { b = 0x12 }

		b2, e2 := http.arena_alloc(work.arena, 5000, mem.DEFAULT_ALIGNMENT)
		if e2 != nil || len(b2) != 5000 { return }
		for &b in b2 { b = 0x34 }

		b3, e3 := http.arena_alloc(work.arena, 64, mem.DEFAULT_ALIGNMENT)
		if e3 != nil { return }
		r3, e4 := http.arena_resize(work.arena, b3, 128, mem.DEFAULT_ALIGNMENT)
		if e4 != nil || raw_data(r3) != raw_data(b3) { return }

		// Non-tail resize forcing another block push.
		r1, e5 := http.arena_resize(work.arena, b1, 4500, mem.DEFAULT_ALIGNMENT)
		if e5 != nil || len(r1) != 4500 || r1[0] != 0x12 || r1[1999] != 0x12 || r1[2000] != 0 {
			return
		}

		work.worker_unused = ((^mem.Tracking_Allocator)(work.worker_alloc.data)).total_allocation_count == 0

		// Standalone bootstrap_arena created and destroyed purely on the worker thread.
		boot, berr := http.bootstrap_arena(nil)
		if berr != nil || boot == nil { return }
		work.boot_backed = boot.backing == work.worker_alloc
		extra, ex_err := http.arena_alloc(boot, 5000, mem.DEFAULT_ALIGNMENT)
		if ex_err != nil || len(extra) != 5000 {
			http.arena_destroy(boot)
			return
		}
		http.arena_destroy(boot)
		work.ok = true
	})
	testing.expect(t, w != nil, "expected worker thread created")
	thread.destroy(w)

	testing.expect(t, work.td_was_nil, "expected http.td to be nil on spawned worker thread")
	testing.expect(t, work.ok, "expected worker allocations and standalone bootstrap_arena to succeed")
	testing.expect(t, work.worker_unused, "expected worker allocations on a to use server allocator")
	testing.expect(t, work.boot_backed, "expected standalone worker bootstrap_arena to bind worker allocator")
	testing.expect_value(t, worker_track.current_memory_allocated, 0)
	testing.expect_value(t, len(worker_track.bad_free_array), 0)
	testing.expect(t, server_track.current_memory_allocated > 0, "expected server_track to hold blocks until destroy")

	// Destroying back on the server thread recycles worker-allocated power-of-two blocks into free_arenas.
	http.arena_destroy(&a)
	testing.expect(t, env.thread.free_arenas[0].head != nil, "expected 4 KiB block recycled into server thread bucket 0")
	testing.expect(t, env.thread.free_arenas[1].head != nil, "expected 8 KiB blocks recycled into server thread bucket 1")

	http._server_thread_free_arenas_destroy(&env.thread)
	testing.expect_value(t, server_track.current_memory_allocated, 0)
	testing.expect_value(t, len(server_track.bad_free_array), 0)
}

@(test)
test_arena_cross_thread_destroy_after_server_out_of_scope :: proc(t: ^testing.T) {
	make_bootstrapped_from_local_server :: proc(t: ^testing.T, backing: mem.Allocator) -> (^http.Arena, []byte) {
		env: Test_Env
		test_env_init(&env, allocator = backing)
		defer http.td = env.prev_td

		boot, err := http.bootstrap_arena(nil)
		testing.expect_value(t, err, nil)
		payload, perr := http.arena_alloc(boot, 5000, mem.DEFAULT_ALIGNMENT)
		testing.expect_value(t, perr, nil)
		for &b in payload { b = 0x7E }
		return boot, payload
	}

	track: mem.Tracking_Allocator
	test_tracking_init(&track)
	defer mem.tracking_allocator_destroy(&track)

	boot, payload := make_bootstrapped_from_local_server(t, mem.tracking_allocator(&track))
	testing.expect(t, boot != nil, "expected bootstrapped arena")
	testing.expect(t, track.current_memory_allocated > 0, "expected backing blocks live before worker destroy")

	Work :: struct {
		boot:    ^http.Arena,
		payload: []byte,
		valid:   bool,
	}
	work := Work{boot = boot, payload = payload}

	w := thread.create_and_start_with_data(&work, proc(data: rawptr) {
		work := (^Work)(data)
		ok := http.td == nil
		for b in work.payload {
			if b != 0x7E { ok = false }
		}
		work.valid = ok
		http.arena_destroy(work.boot)
	})
	testing.expect(t, w != nil, "expected worker thread created")
	thread.destroy(w)

	testing.expect(t, work.valid, "expected valid payload on worker thread after Server went out of scope")
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
test_arena_multi_server_allocator_isolation :: proc(t: ^testing.T) {
	track_a: mem.Tracking_Allocator
	test_tracking_init(&track_a)
	defer mem.tracking_allocator_destroy(&track_a)

	track_b: mem.Tracking_Allocator
	test_tracking_init(&track_b)
	defer mem.tracking_allocator_destroy(&track_b)

	s_a := http.make_server({}, mem.tracking_allocator(&track_a))
	s_b := http.make_server({}, mem.tracking_allocator(&track_b))

	thread_a := http.Server_Thread{s = &s_a, id = 1}
	thread_b := http.Server_Thread{s = &s_b, id = 2}
	prev_td := http.td
	defer {
		http.td = prev_td
		http._server_thread_free_arenas_destroy(&thread_a)
		http._server_thread_free_arenas_destroy(&thread_b)
	}

	// Pre-populate Server B's bucket 1 freelist with a Server B block.
	http.td = &thread_b
	b := http.get_arena(nil)
	_, b_err := http.arena_alloc(&b, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, b_err, nil)
	b_cached := b.tail
	http.arena_destroy(&b)
	testing.expect(t, thread_b.free_arenas[1].head == b_cached, "expected Server B 8 KiB block cached on thread_b")
	b_allocs_before := track_b.total_allocation_count
	b_frees_before  := track_b.total_free_count

	// Create and allocate on Server A.
	http.td = &thread_a
	a := http.get_arena(nil)
	_, a1_err := http.arena_alloc(&a, 100, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, a1_err, nil)
	testing.expect_value(t, track_a.total_allocation_count, 1)

	// Migrate Arena `a` onto Server B's thread: must neither steal Server B's cached block nor pollute thread_b.free_arenas.
	http.td = &thread_b
	_, a2_err := http.arena_alloc(&a, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, a2_err, nil)
	testing.expect(t, a.tail != b_cached, "expected Server A arena not to steal Server B cached block")
	testing.expect(t, thread_b.free_arenas[1].head == b_cached, "expected Server B cached block untouched in bucket 1")
	testing.expect_value(t, track_a.total_allocation_count, 2)

	http.arena_destroy(&a)
	testing.expect(t, thread_b.free_arenas[0].head == nil, "expected Server A 4 KiB block not pushed into thread_b")
	testing.expect(t, thread_b.free_arenas[1].head == b_cached, "expected Server A 8 KiB block not pushed into thread_b")
	testing.expect_value(t, track_b.total_allocation_count, b_allocs_before)
	testing.expect_value(t, track_b.total_free_count, b_frees_before)
	testing.expect_value(t, track_a.current_memory_allocated, 0)
	testing.expect_value(t, len(track_a.bad_free_array), 0)
	testing.expect_value(t, len(track_b.bad_free_array), 0)
}

@(test)
test_arena_same_server_different_worker_thread :: proc(t: ^testing.T) {
	counter := Test_Counting_Allocator{backing = context.allocator}
	s := http.make_server({}, test_counting_allocator(&counter))

	thread_1 := http.Server_Thread{s = &s, id = 1}
	thread_2 := http.Server_Thread{s = &s, id = 2}
	prev_td := http.td
	defer {
		http.td = prev_td
		http._server_thread_free_arenas_destroy(&thread_1)
		http._server_thread_free_arenas_destroy(&thread_2)
	}

	http.td = &thread_1
	a1 := http.get_arena(nil)
	_, e1 := http.arena_alloc(&a1, 64, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, e1, nil)
	block0 := a1.tail
	_, e2 := http.arena_alloc(&a1, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, e2, nil)
	block1 := a1.tail
	testing.expect_value(t, counter.alloc_count, 2)

	// Destroy on thread_2 of the same server: recycles directly into thread_2.free_arenas.
	http.td = &thread_2
	http.arena_destroy(&a1)
	testing.expect(t, thread_2.free_arenas[0].head == block0, "expected 4 KiB block recycled into thread_2 bucket 0")
	testing.expect(t, thread_2.free_arenas[1].head == block1, "expected 8 KiB block recycled into thread_2 bucket 1")
	for b in thread_1.free_arenas {
		testing.expect(t, b.head == nil, "expected thread_1 free_arenas empty")
	}
	testing.expect_value(t, counter.free_count, 0)

	// Subsequent allocation on thread_2 reuses both blocks without new backing allocations.
	a2 := http.get_arena(nil)
	_, e3 := http.arena_alloc(&a2, 64, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, e3, nil)
	testing.expect(t, a2.tail == block0, "expected block0 reused on thread_2")
	_, e4 := http.arena_alloc(&a2, 5000, mem.DEFAULT_ALIGNMENT)
	testing.expect_value(t, e4, nil)
	testing.expect(t, a2.tail == block1, "expected block1 reused on thread_2")
	testing.expect_value(t, counter.alloc_count, 2)

	http.arena_destroy(&a2)
	http._server_thread_free_arenas_destroy(&thread_2)
	testing.expect_value(t, counter.free_count, 2)
}

@(test)
test_arena_temp_free_all_without_td :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	test_tracking_init(&track)
	defer mem.tracking_allocator_destroy(&track)

	env: Test_Env
	test_env_init(&env, allocator = mem.tracking_allocator(&track))
	defer test_env_destroy(&env)

	c := http.Connection{
		temp_arena = http.get_arena(nil),
	}
	c.temp_arena.c = &c
	c.scanner.c = &c
	c.scanner.allocator = &c.temp_arena

	buf, buf_err := make([]byte, http.MULTIPLIER, http.temp_allocator(&c))
	testing.expect_value(t, buf_err, nil)
	unread := "UNREAD_PAYLOAD"
	c.scanner.buf        = buf
	c.scanner.read_head  = 0
	c.scanner.write_head = copy(buf, unread)

	// Push an overflow block in temp_arena before running free_all on a worker thread.
	extra, extra_err := make([]byte, 5000, http.temp_allocator(&c))
	testing.expect_value(t, extra_err, nil)
	extra[0] = 0x55
	testing.expect_value(t, track.total_allocation_count, 2)

	Work :: struct {
		c:                ^http.Connection,
		expected_unread:  string,
		td_was_nil:       bool,
		preserved_unread: bool,
	}
	work := Work{
		c               = &c,
		expected_unread = unread,
	}

	w := thread.create_and_start_with_data(&work, proc(data: rawptr) {
		work := (^Work)(data)
		work.td_was_nil = http.td == nil

		free_all(http.temp_allocator(work.c))
		got := string(work.c.scanner.buf[work.c.scanner.read_head:work.c.scanner.write_head])
		work.preserved_unread = got == work.expected_unread
		http.arena_destroy(&work.c.temp_arena)
	})
	testing.expect(t, w != nil, "expected worker thread created")
	thread.destroy(w)

	testing.expect(t, work.td_was_nil, "expected http.td to be nil on spawned worker thread")
	testing.expect(t, work.preserved_unread, "expected unread scanner bytes preserved across _scanner_free_all on worker thread")
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
test_free_arenas_low_watermark_trim :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	test_tracking_init(&track)
	defer mem.tracking_allocator_destroy(&track)

	env: Test_Env
	test_env_init(&env, allocator = mem.tracking_allocator(&track))
	defer test_env_destroy(&env)

	push_blocks :: proc(t: ^testing.T, n: int, size: int) {
		blocks := make([]^http._Arena_Block, n, context.temp_allocator)
		for i in 0 ..< n {
			b, err := http._server_thread_get_free_arena(size)
			testing.expect_value(t, err, nil)
			blocks[i] = b
		}
		for b in blocks {
			http._server_thread_put_free_arena(b)
		}
	}

	// 1. Steady traffic (all cached blocks acquired and released during interval) frees 0 blocks.
	push_blocks(t, 4, 1)
	http._server_thread_free_arenas_trim(&env.thread) // Latch watermark at 4.
	testing.expect_value(t, env.thread.free_arenas[0].count, u32(4))
	testing.expect_value(t, env.thread.free_arenas[0].min_count, u32(4))

	push_blocks(t, 4, 1) // Acquires and releases all 4, dropping min_count to 0.
	testing.expect_value(t, env.thread.free_arenas[0].min_count, u32(0))
	http._server_thread_free_arenas_trim(&env.thread)
	testing.expect_value(t, env.thread.free_arenas[0].count, u32(4))

	// 2. Idle excess halves each trim interval until fully reclaimed (4 -> 2 -> 1 -> 0).
	http._server_thread_free_arenas_trim(&env.thread)
	testing.expect_value(t, env.thread.free_arenas[0].count, u32(2))
	http._server_thread_free_arenas_trim(&env.thread)
	testing.expect_value(t, env.thread.free_arenas[0].count, u32(1))
	http._server_thread_free_arenas_trim(&env.thread)
	testing.expect_value(t, env.thread.free_arenas[0].count, u32(0))
	testing.expect(t, env.thread.free_arenas[0].head == nil, "expected empty freelist after full decay")
	testing.expect_value(t, track.current_memory_allocated, 0)

	// 3. Partial activity trims only half of the untouched low-watermark excess.
	push_blocks(t, 6, 1)
	http._server_thread_free_arenas_trim(&env.thread) // Latch watermark at 6.
	push_blocks(t, 2, 1)                              // Uses 2 blocks, lowering min_count to 4.
	testing.expect_value(t, env.thread.free_arenas[0].min_count, u32(4))
	http._server_thread_free_arenas_trim(&env.thread) // Frees (4+1)/2 = 2 blocks.
	testing.expect_value(t, env.thread.free_arenas[0].count, u32(4))

	http._server_thread_free_arenas_destroy(&env.thread)
	testing.expect_value(t, track.current_memory_allocated, 0)

	// 4. Per-tick budget caps frees at MAX_ARENA_TRIM_PER_TICK and drains larger buckets first.
	push_blocks(t, 160, 1)             // Bucket 0 (4 KiB)
	push_blocks(t, 4, 16*1024 - 128)   // Bucket 2 (16 KiB)
	testing.expect_value(t, env.thread.free_arenas[0].count, u32(160))
	testing.expect_value(t, env.thread.free_arenas[2].count, u32(4))

	http._server_thread_free_arenas_trim(&env.thread) // Latch watermarks.
	http._server_thread_free_arenas_trim(&env.thread) // Trims 2 from bucket 2 and 62 from bucket 0 (64 total).
	testing.expect_value(t, env.thread.free_arenas[2].count, u32(2))
	testing.expect_value(t, env.thread.free_arenas[0].count, u32(98))

	http._server_thread_free_arenas_destroy(&env.thread)
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
test_arena_free_computes_offset_from_ptr :: proc(t: ^testing.T) {
	arena := http.Arena{backing = context.allocator}
	defer http.arena_destroy(&arena)

	a, err_a := http.arena_alloc(&arena, 16, 8)
	testing.expect_value(t, err_a, nil)
	for &x in a { x = 0xAA }

	b, err_b := http.arena_alloc(&arena, 128, 64)
	testing.expect_value(t, err_b, nil)

	// Shrink b in place to 1 byte, then free with the stale pre-shrink size (128).
	b_shrunk, resize_err := http.arena_resize(&arena, b, 1, 64)
	testing.expect_value(t, resize_err, nil)

	free_err := http.arena_free(&arena, raw_data(b_shrunk), 128)
	testing.expect_value(t, free_err, nil)
	testing.expect(t, arena.tail.offset >= size_of(http._Arena_Block) + len(a), "arena offset must not underflow past earlier allocations or block header")

	c, err_c := http.arena_alloc(&arena, 32, 8)
	testing.expect_value(t, err_c, nil)
	testing.expect_value(t, len(c), 32)
	for x in a {
		testing.expect_value(t, x, u8(0xAA))
	}

	non_tail_err := http.arena_free(&arena, raw_data(a), len(a))
	testing.expect_value(t, non_tail_err, mem.Allocator_Error.Mode_Not_Implemented)
}
