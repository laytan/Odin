#+vet explicit-allocators
package http

import "base:intrinsics"
import "base:runtime"
import "base:sanitizer"

import "core:math"
import "core:math/bits"
import "core:mem"

/*
Thread-safety contract:
An `Arena` may have its ownership transferred across threads: once initialized on a server thread
(or lazily bound on first block push), `arena_alloc`, `arena_resize`, `arena_free`, `arena_free_all`,
and `arena_destroy` may be called from non-server worker threads or another server's thread,
assuming the underlying backing allocator (`Server.allocator`, or `context.allocator`) is thread-safe.

Blocks at or below `MAX_POOLED_BLOCK_SIZE` are acquired from and recycled into the current server
thread's lock-free `td.free_arenas` cache only when `td != nil` and its backing allocator matches
`Arena.backing`; otherwise blocks are allocated from and freed directly to `Arena.backing`.

Simultaneous unsynchronized calls on the same `Arena` instance from multiple threads are NOT supported.
*/
Arena :: struct {
	c:       ^Connection,
	tail:    ^_Arena_Block,
	backing: mem.Allocator,
}

get_arena :: proc(c: ^Connection) -> Arena {
	return {
		c       = c,
		backing = _arena_default_backing(c),
	}
}

bootstrap_arena :: proc(c: ^Connection) -> (arena: ^Arena, err: mem.Allocator_Error) #optional_allocator_error {
	backing := _arena_default_backing(c)
	block := _arena_block_acquire(backing) or_return
	arena, err = new(Arena, mem.arena_allocator(block))
	if err != nil {
		_arena_block_release(backing, block)
		return nil, err
	}
	arena.c       = c
	arena.tail    = block
	arena.backing = backing
	return arena, nil
}

arena_allocator :: proc(a: ^Arena) -> mem.Allocator {
	return _arena_allocator(a, true)
}

arena_alloc :: proc(a: ^Arena, size, align: int, should_zero := true) -> (bs: []byte, err: mem.Allocator_Error) {
	if size == 0 { return nil, nil }
	if size < 0  { return nil, .Invalid_Argument }
	align := align == 0 ? mem.DEFAULT_ALIGNMENT : align
	if align < 0 || !math.is_power_of_two(align) { return nil, .Invalid_Argument }

	arena := a.tail
	if arena == nil { arena = _push_arena_block(a, size, align) or_return }

	bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, align)
	if err == .Out_Of_Memory {
		arena = _push_arena_block(a, size, align) or_return
		bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, align)
	}

	if err == nil {
		if should_zero {
			mem.zero_slice(bs)
		}
		arena.last = raw_data(bs)
	}
	return
}

arena_resize :: proc(a: ^Arena, old_memory: []byte, size, align: int, should_zero := true) -> (bs: []byte, err: mem.Allocator_Error) {
	if raw_data(old_memory) == nil {
		return arena_alloc(a, size, align, should_zero)
	}
	if size == 0 {
		return nil, arena_free(a, raw_data(old_memory), len(old_memory))
	}
	if size < 0 {
		return nil, .Invalid_Argument
	}
	align := align == 0 ? mem.DEFAULT_ALIGNMENT : align
	if align < 0 || !math.is_power_of_two(align) {
		return nil, .Invalid_Argument
	}

	// Fast path: grow or shrink the most recent allocation in place.
	if bs, err = _arena_block_resize_in_place(a.tail, old_memory, size, align, should_zero); err == nil {
		return
	}

	// Non-tail shrink or same-size resize when alignment is already satisfied: return prefix in place
	// without allocating or clobbering arena.last (which points to a later allocation).
	if size <= len(old_memory) && mem.is_aligned(raw_data(old_memory), align) {
		return old_memory[:size], nil
	}

	// Allocate a new region (reusing current block or pushing a new block) and copy the prefix.
	bs, err = arena_alloc(a, size, align, should_zero = false)
	if err != nil {
		return
	}

	copy_len := min(len(old_memory), size)
	if copy_len > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(bs), raw_data(old_memory), copy_len)
	}
	if should_zero && copy_len < size {
		mem.zero_slice(bs[copy_len:])
	}
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
	if a == nil || a.tail == nil {
		return
	}
	// Snapshot backing and detach tail before releasing any blocks: for bootstrapped arenas,
	// `a` itself lives inside the oldest block in the chain.
	backing := a.backing
	if backing.procedure == nil {
		backing = _arena_default_backing(a.c)
	}
	arena := a.tail
	a.tail = nil
	for arena != nil {
		prev := arena.prev
		_arena_block_release(backing, arena)
		arena = prev
	}
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
BUCKETS    :: 13   // Last bucket starts at 16 MiB

@(private)
MAX_POOLED_BLOCK_SIZE :: 1 << (SHIFT + BUCKETS - 1)
#assert(MAX_POOLED_BLOCK_SIZE == 16 * mem.Megabyte)

_bucket_for :: proc(min_size: int) -> int {
	assert(min_size > 0)
	aligned := uint(math.next_power_of_two(min_size))
	return clamp(int(bits.log2(aligned)) - SHIFT, 0, BUCKETS-1)
}

_bucket_to_put :: proc(size: uint) -> int {
	assert(size > 0)
	return clamp(int(bits.log2(size)) - SHIFT, 0, BUCKETS-1)
}

@(private)
_arena_backing_allocator :: proc(s: ^Server) -> mem.Allocator {
	if s != nil && s.allocator.procedure != nil {
		return s.allocator
	}
	return context.allocator
}

@(private)
_arena_default_backing :: proc(c: ^Connection) -> mem.Allocator {
	if c != nil {
		if c.transaction_arena.backing.procedure != nil {
			return c.transaction_arena.backing
		}
		if c.temp_arena.backing.procedure != nil {
			return c.temp_arena.backing
		}
	}
	if td != nil {
		return _arena_backing_allocator(td.s)
	}
	return context.allocator
}

@(private="file")
_arena_block_free :: proc(arena: ^_Arena_Block, backing: mem.Allocator) {
	data := arena.data
	sanitizer.address_unpoison(data[size_of(_Arena_Block):])
	_ = mem.free_bytes(data, backing)
}

@(private="file")
_arena_block_reset :: proc(arena: ^_Arena_Block) -> ^_Arena_Block {
	arena.offset = size_of(_Arena_Block)
	arena.peak_used, arena.temp_count = 0, 0
	arena.last = nil
	arena.prev = nil
	sanitizer.address_unpoison(arena.data[size_of(_Arena_Block):])
	return arena
}

@(private)
_arena_block_acquire :: proc(backing: mem.Allocator, size: int = 0, align := mem.DEFAULT_ALIGNMENT) -> (arena: ^_Arena_Block, err: mem.Allocator_Error) #optional_allocator_error {
	if size < 0 {
		return nil, .Invalid_Argument
	}
	backing := backing
	if backing.procedure == nil {
		backing = context.allocator
	}
	align     := align == 0 ? mem.DEFAULT_ALIGNMENT : align
	align_pad := max(0, align - align_of(_Arena_Block))
	overhead  := size_of(_Arena_Block) + align_pad
	if size > max(int) - overhead {
		return nil, .Out_Of_Memory
	}
	needed     := max(ARENA_SIZE, overhead + size)
	alloc_size := needed

	if needed <= MAX_POOLED_BLOCK_SIZE {
		bucket := _bucket_for(needed)
		if td != nil && _arena_backing_allocator(td.s) == backing {
			if free_arena := td.free_arenas[bucket]; free_arena != nil {
				td.free_arenas[bucket] = free_arena.prev
				return _arena_block_reset(free_arena), nil
			}
		}
		alloc_size = 1 << (uint(bucket) + SHIFT)
	}

	data := mem.alloc_bytes_non_zeroed(alloc_size, align_of(_Arena_Block), backing) or_return
	sanitizer.address_unpoison(data)

	arena = (^_Arena_Block)(raw_data(data))
	arena^ = {
		base = {
			data   = data,
			offset = size_of(_Arena_Block),
		},
	}

	return arena, nil
}

@(private)
_arena_block_release :: proc(backing: mem.Allocator, arena: ^_Arena_Block) {
	backing := backing
	if backing.procedure == nil {
		backing = context.allocator
	}
	if len(arena.data) <= MAX_POOLED_BLOCK_SIZE && td != nil && _arena_backing_allocator(td.s) == backing {
		sanitizer.address_poison(arena.data[size_of(_Arena_Block):])

		bucket := _bucket_to_put(uint(len(arena.data)))
		arena.prev = td.free_arenas[bucket]
		td.free_arenas[bucket] = arena
		return
	}

	_arena_block_free(arena, backing)
}

_server_thread_get_free_arena :: proc(size: int = 0, align := mem.DEFAULT_ALIGNMENT) -> (arena: ^_Arena_Block, err: mem.Allocator_Error) #optional_allocator_error {
	backing := _arena_backing_allocator(td != nil ? td.s : nil)
	return _arena_block_acquire(backing, size, align)
}

_server_thread_put_free_arena :: proc(arena: ^_Arena_Block) {
	backing := _arena_backing_allocator(td != nil ? td.s : nil)
	_arena_block_release(backing, arena)
}

_server_thread_free_arenas_destroy :: proc(t: ^Server_Thread) {
	backing := _arena_backing_allocator(t.s)
	for &head in t.free_arenas {
		for block := head; block != nil; {
			prev := block.prev
			_arena_block_free(block, backing)
			block = prev
		}
		head = nil
	}
}

_push_arena_block :: proc(a: ^Arena, size, align: int) -> (arena: ^_Arena_Block, err: mem.Allocator_Error) {
	if a.backing.procedure == nil {
		a.backing = _arena_default_backing(a.c)
	}
	arena = _arena_block_acquire(a.backing, size, align == 0 ? mem.DEFAULT_ALIGNMENT : align) or_return
	arena.prev = a.tail
	a.tail = arena
	return arena, nil
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
	if a == nil || old_memory == nil || old_memory != a.last {
		return nil, .Invalid_Pointer
	}

	if size <= 0 {
		return nil, .Invalid_Argument
	}

	if !mem.is_aligned(old_memory, alignment) {
		return nil, .Invalid_Pointer
	}

	diff := size - len(old_data)
	if a.offset + diff < size_of(_Arena_Block) {
		return nil, .Invalid_Argument
	}
	if a.offset + diff > len(a.data) {
		return nil, .Out_Of_Memory
	}

	if should_zero && diff > 0 {
		mem.zero_slice(a.data[a.offset:][:diff])
	}

	a.offset += diff
	a.peak_used = max(a.peak_used, a.offset)

	raw := transmute(runtime.Raw_Slice)old_data
	raw.len += diff
	return transmute([]byte)raw, nil
}

