package tests_http2

import http "core:http2"
import "core:mem"
import "core:testing"

@(test)
test_free_arenas_low_watermark_trim :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	srv := http.Server{allocator = mem.tracking_allocator(&track)}
	thread := http.Server_Thread{s = &srv, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

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
	http._server_thread_free_arenas_trim(&thread) // Latch watermark at 4.
	testing.expect_value(t, thread.free_arenas[0].count, u32(4))
	testing.expect_value(t, thread.free_arenas[0].min_count, u32(4))

	push_blocks(t, 4, 1) // Acquires and releases all 4, dropping min_count to 0.
	testing.expect_value(t, thread.free_arenas[0].min_count, u32(0))
	http._server_thread_free_arenas_trim(&thread)
	testing.expect_value(t, thread.free_arenas[0].count, u32(4))

	// 2. Idle excess halves each trim interval until fully reclaimed (4 -> 2 -> 1 -> 0).
	http._server_thread_free_arenas_trim(&thread)
	testing.expect_value(t, thread.free_arenas[0].count, u32(2))
	http._server_thread_free_arenas_trim(&thread)
	testing.expect_value(t, thread.free_arenas[0].count, u32(1))
	http._server_thread_free_arenas_trim(&thread)
	testing.expect_value(t, thread.free_arenas[0].count, u32(0))
	testing.expect(t, thread.free_arenas[0].head == nil, "expected empty freelist after full decay")
	testing.expect_value(t, track.current_memory_allocated, 0)

	// 3. Partial activity trims only half of the untouched low-watermark excess.
	push_blocks(t, 6, 1)
	http._server_thread_free_arenas_trim(&thread) // Latch watermark at 6.
	push_blocks(t, 2, 1)                          // Uses 2 blocks, lowering min_count to 4.
	testing.expect_value(t, thread.free_arenas[0].min_count, u32(4))
	http._server_thread_free_arenas_trim(&thread) // Frees (4+1)/2 = 2 blocks.
	testing.expect_value(t, thread.free_arenas[0].count, u32(4))

	http._server_thread_free_arenas_destroy(&thread)
	testing.expect_value(t, track.current_memory_allocated, 0)

	// 4. Per-tick budget caps frees at MAX_ARENA_TRIM_PER_TICK and drains larger buckets first.
	push_blocks(t, 160, 1)             // Bucket 0 (4 KiB)
	push_blocks(t, 4, 16*1024 - 128)   // Bucket 2 (16 KiB)
	testing.expect_value(t, thread.free_arenas[0].count, u32(160))
	testing.expect_value(t, thread.free_arenas[2].count, u32(4))

	http._server_thread_free_arenas_trim(&thread) // Latch watermarks.
	http._server_thread_free_arenas_trim(&thread) // Trims 2 from bucket 2 and 62 from bucket 0 (64 total).
	testing.expect_value(t, thread.free_arenas[2].count, u32(2))
	testing.expect_value(t, thread.free_arenas[0].count, u32(98))

	http._server_thread_free_arenas_destroy(&thread)
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
