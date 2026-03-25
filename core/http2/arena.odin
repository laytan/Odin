#+vet explicit-allocators
package http

import "base:intrinsics"
import "base:runtime"
import "base:sanitizer"

import "core:log"
import "core:math"
import "core:math/bits"
import "core:mem"
import "core:mem/virtual"

Arena :: struct {
	c:    ^Connection,
	tail: ^_Arena_Block,
}

get_arena :: proc(c: ^Connection) -> Arena {
	return {
		c = c,
	}
}

bootstrap_arena :: proc(c: ^Connection) -> ^Arena {
	block := _server_thread_get_free_arena()
	arena := new(Arena, mem.arena_allocator(block))
	arena.c    = c
	arena.tail = block
	return arena
}

arena_allocator :: proc(a: ^Arena) -> mem.Allocator {
	return _arena_allocator(a, true)
}

arena_alloc :: proc(a: ^Arena, size, align: int, should_zero := true) -> (bs: []byte, err: mem.Allocator_Error) {
	arena := a.tail
	if arena == nil { arena = _push_arena_block(a, size, align) }

	bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, align)
	if err == .Out_Of_Memory {
		arena = _push_arena_block(a, size, align)
		bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, align)
	}

	if err == nil && should_zero {
		mem.zero_slice(bs)
	}

	arena.last = raw_data(bs)
	return
}

arena_resize :: proc(a: ^Arena, old_memory: []byte, size, align: int, should_zero := true) -> (bs: []byte, err: mem.Allocator_Error) {
	arena := a.tail
	if arena == nil { arena = _push_arena_block(a, size, align) }

	bs, err = _arena_block_resize_in_place(arena, old_memory, size, align, should_zero)
	if err != nil {
		bs, err = mem._default_resize_bytes_align(old_memory, size, align, should_zero, mem.arena_allocator(arena))
		if err == .Out_Of_Memory {
			arena = _push_arena_block(a, size, align)
			bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, align)
			if err == nil {
				intrinsics.mem_copy_non_overlapping(raw_data(bs), raw_data(old_memory), len(old_memory))
				if should_zero {
					mem.zero_slice(bs[len(old_memory):])
				}
			}
		}
	}
	arena.last = raw_data(bs)
	return
}

arena_free :: proc(a: ^Arena, ptr: rawptr, size: int) -> mem.Allocator_Error {
	if ptr == nil { return nil }

	arena := a.tail
	if arena == nil || size <= 0 { return .Invalid_Argument }

	if ptr != arena.last { return .Mode_Not_Implemented }

	arena.last    = nil
	arena.offset -= size
	return nil 
}

arena_destroy :: proc(a: ^Arena) {
	arena := a.tail
	for arena != nil {
		prev := arena.prev
		_server_thread_put_free_arena(arena)
		arena = prev
	}
	a.tail = nil
}

arena_free_all :: arena_destroy

_Arena_Block :: struct {
	using base: mem.Arena,
	last: rawptr,
	prev: ^_Arena_Block,
}

@(private)
ARENA_SIZE :: 4096
@(private)
SHIFT      :: 12   // First bucket starts at 4 KiB
@(private)
BUCKETS    :: 17   // Last bucket starts at 256 MiB

@(private)
LAST_BUCKET_FROM_SIZE :: 1 << (SHIFT + BUCKETS-1)
#assert(LAST_BUCKET_FROM_SIZE == 256 * mem.Megabyte)

_bucket_for :: proc(min_size: int) -> int {
	assert(min_size > 0)
	aligned := uint(math.next_power_of_two(min_size))
	return clamp(int(bits.log2(aligned)) - SHIFT, 0, BUCKETS-1)
}

_bucket_to_put :: proc(size: uint) -> int {
	assert(size > 0)
	return clamp(int(bits.log2(size)) - SHIFT, 0, BUCKETS-1)
}

_server_thread_get_free_arena :: proc(size: int = 0, align := mem.DEFAULT_ALIGNMENT) -> ^_Arena_Block {
	size   := size
	size    = max(ARENA_SIZE, mem.align_forward_int(size_of(_Arena_Block), align) + size)
	bucket := _bucket_for(size)

	if bucket == BUCKETS-1 {
		arena := td.free_arenas[bucket]
		if arena != nil {
			if len(arena.data) < size {
				{
					context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
					log.debugf("http[t=%v]: size=%M, bucket=%v, got=%M", td.id, size, bucket, len(arena.data))
				}

				td.free_arenas[bucket] = nil
				arena.offset = size_of(_Arena_Block)
				arena.peak_used, arena.temp_count = 0, 0
				arena.prev = nil

				sanitizer.address_unpoison(arena.data[size_of(_Arena_Block):])
				return arena
			}

			for prev := arena.prev; prev != nil; arena, prev = prev, prev.prev {
				if len(prev.data) < size {
					continue
				}

				{
					context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
					log.debugf("http[t=%v]: size=%M, bucket=%v, got=%M", td.id, size, bucket, len(prev.data))
				}

				arena.prev = prev.prev
				prev.offset = size_of(_Arena_Block)
				prev.peak_used, prev.temp_count = 0, 0
				prev.prev = nil

				sanitizer.address_unpoison(prev.data[size_of(_Arena_Block):])
				return prev
			}
		}
	} else {
		for check in bucket..<BUCKETS {
			free_arena := td.free_arenas[check]
			if free_arena == nil {
				continue
			}

			{
				context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
				log.debugf("http[t=%v]: size=%M, bucket=%v, check=%v, got=%M", td.id, size, bucket, check, len(free_arena.data))
			}

			td.free_arenas[check] = free_arena.prev
			free_arena.offset = size_of(_Arena_Block)
			free_arena.peak_used, free_arena.temp_count = 0, 0
			free_arena.prev = nil

			sanitizer.address_unpoison(free_arena.data[size_of(_Arena_Block):])
			return free_arena
		}
	}

	{
		context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
		log.debugf("http[t=%v]: size=%M, bucket=%v", td.id, size, bucket)
	}

	data, err := virtual.arena_alloc(&td.s.temp_allocator_backing, uint(size), uint(align))
	assert(err == nil) // TODO: Handle

	arena := (^_Arena_Block)(raw_data(data))
	arena.data   = data
	arena.offset = size_of(_Arena_Block)

	return arena
}

_server_thread_put_free_arena :: proc(arena: ^_Arena_Block) {
	sanitizer.address_poison(arena.data[size_of(_Arena_Block):])

	bucket := _bucket_to_put(len(arena.data))
	arena.prev = td.free_arenas[bucket]
	td.free_arenas[bucket] = arena

	{
		context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
		log.debugf("http[t=%v]: size=%M, bucket=%v", td.id, len(arena.data), bucket)
	}
}

_push_arena_block :: proc(a: ^Arena, size, align: int) -> ^_Arena_Block {
	arena := _server_thread_get_free_arena(size, align == 0 ? mem.DEFAULT_ALIGNMENT : align)
	arena.prev = a.tail
	a.tail = arena
	return arena
}

_arena_allocator :: proc(a: ^Arena, $FREE_ALL: bool) -> mem.Allocator {
	return {
		data = a,
		procedure = proc(allocator_data: rawptr, mode: runtime.Allocator_Mode,
                             size, alignment: int,
                             old_memory: rawptr, old_size: int,
                             location: runtime.Source_Code_Location) -> (bs: []byte, err: runtime.Allocator_Error) {
			a := (^Arena)(allocator_data)
			switch mode {
			case .Alloc:
				return arena_alloc(a, size, alignment)
			case .Alloc_Non_Zeroed:
				return arena_alloc(a, size, alignment, false)
			case .Resize:
				return arena_resize(a, mem.byte_slice(old_memory, old_size), size, alignment)
			case .Resize_Non_Zeroed:
				return arena_resize(a, mem.byte_slice(old_memory, old_size), size, alignment, false)
			case .Query_Features:
				set := (^mem.Allocator_Mode_Set)(old_memory)
				if set != nil {
					set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Query_Features}
					when FREE_ALL {
						set^ += {.Free_All}
					}
				}
				return nil, nil
			case .Free:
				return nil, arena_free(a, old_memory, old_size)
			case .Free_All:
				when FREE_ALL {
					if a.c == nil || !_scanner_free_all(&a.c.scanner, a) {
						arena_free_all(a)
					}
					return nil, nil
				} else {
					return nil, .Mode_Not_Implemented
				}
			case .Query_Info:
				return nil, .Mode_Not_Implemented
			case:
				return nil, nil
			}
		},
	}
}

_arena_block_resize_in_place :: proc(a: ^_Arena_Block, old_data: []byte, size, alignment: int, should_zero: bool) -> ([]byte, mem.Allocator_Error) {
	old_memory := raw_data(old_data)
	if old_memory == nil || old_memory != a.last {
		return nil, .Invalid_Pointer
	}

	if size <= 0 {
		return nil, .Invalid_Argument
	}

	if !mem.is_aligned(old_memory, alignment) {
		return nil, .Invalid_Pointer
	}

	diff := size - len(old_data)
	if a.offset + diff > len(a.data) {
		return nil, .Out_Of_Memory
	}

	if should_zero && diff > 0 {
		mem.zero_slice(a.data[a.offset:][:diff])
	}

	a.offset += diff

	raw := transmute(runtime.Raw_Slice)old_data
	raw.len += diff
	return transmute([]byte)raw, nil
}

