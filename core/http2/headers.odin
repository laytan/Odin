#+vet explicit-allocators
package http

import "base:intrinsics"
import "base:runtime"

import "core:encoding/endian"
import "core:mem"
import "core:strings"

INITIAL_CAP :: 16
LOAD_FACTOR :: .7

Header_Spot :: struct {
	key:   string,
	value: string,
	hash:  u64,
}

Headers :: struct {
	allocator: runtime.Allocator,
	spots:     []Header_Spot,
	len:       int,
	threshold: int,
}

_headers_make :: proc(allocator := context.allocator) -> Headers {
	return {
		allocator = allocator,
	}
}

headers_len :: proc(m: Headers) -> int {
	return m.len
}

headers_destroy :: proc(m: Headers) {
	delete(m.spots, m.allocator)
}

headers_iter :: proc(m: ^Headers, state: ^int) -> (string, string, bool) {
	if state^ >= len(m.spots) {
		return {}, {}, false
	}

	for spot, i in m.spots[state^:] {
		if spot.hash != 0 {
			state^ += i + 1
			return spot.key, spot.value, true
		}
	}

	return {}, {}, false
}

headers_set :: proc(m: ^Headers, key, value: string, loc := #caller_location) -> mem.Allocator_Error {
	assert(!_HEADERS_ARE_READONLY(m^), "these headers are readonly, did you accidentally try to set a header on the server request or client response?", loc)

	_headers_set_with_hash(m, Header_Spot{
		key   = key,
		value = value,
		hash  = _headers_hash_key(key),
	})

	return nil
}

headers_add :: proc(m: ^Headers, key, value: string, loc := #caller_location) -> mem.Allocator_Error {
	assert(!_HEADERS_ARE_READONLY(m^), "these headers are readonly, did you accidentally try to set a header on the server request or client response?", loc)

	_headers_add_with_hash(m, Header_Spot{
		key   = key,
		value = value,
		hash  = _headers_hash_key(key),
	})

	return nil
}

/*
Returns the first instance of this header key.

If you expect multiple of the same headers, use the `headers_get_all_iterator` procedures.
*/
headers_get :: proc(m: Headers, key: string) -> (value: string, ok: bool) #optional_ok {
	spot := #force_inline _headers_spot(m, key)
	if spot == nil { return }
	return spot.value, true
}

Headers_Get_All_Iterator :: struct {
	h:    ^Headers,
	key:  string,
	hash: u64,
	mask: u64,
	idx:  u64,
}

headers_get_all_iterator :: proc(h: ^Headers, key: string) -> Headers_Get_All_Iterator {
	hash := _headers_hash_key(key)
	mask := u64(len(h.spots) - 1)
	return {
		h    = h,
		key  = key,
		hash = hash,
		mask = mask,
		idx  = hash & mask,
	}
}

headers_get_all_iter :: proc(iter: ^Headers_Get_All_Iterator) -> (value: string, ok: bool) #no_bounds_check {
	if iter.h.len == 0 { return }

	for {
		entry := &iter.h.spots[iter.idx]
		if entry.hash == 0 { return }

		iter.idx = (iter.idx + 1) & iter.mask

		if iter.hash == entry.hash && _headers_eq(iter.key, entry.key) {
			return entry.value, true
		}
	}
}

headers_has :: proc(m: Headers, key: string) -> bool {
	_, has := #force_inline headers_get(m, key)
	return has
}

headers_entry :: proc(m: ^Headers, key: string) -> (key_ptr, val_ptr: ^string, just_inserted: bool, err: mem.Allocator_Error) {
	if m.len >= m.threshold {
		_headers_grow(m) or_return
	}

	hashed := _headers_hash_key(key)
	mask   := u64(len(m.spots) - 1)
	idx    := hashed & mask
	for {
		candidate := &m.spots[idx]

		if candidate.hash == 0 || (candidate.hash == hashed && _headers_eq(candidate.key, key)) {
			if candidate.hash == 0 {
				m.len += 1
				just_inserted  = true
				candidate.key  = key
				candidate.hash = hashed
			}

			key_ptr = &candidate.key
			val_ptr = &candidate.value
			return
		}

		idx = (idx + 1) & mask
	}
}

headers_delete :: proc(m: Headers, key: string) -> (deleted_key, deleted_value: string) {
	return #force_inline _headers_delete_with_hash(m, key, _headers_hash_key(key))
}

headers_valid_key :: proc(key: string) -> bool {
	for b in transmute([]byte)key {
		(#force_inline strings.ascii_set_contains(TOKEN_SET, b)) or_return
	}
	return len(key) > 0
}

/*
Iterates the header value, replacing `\r` and `\n` with spaces.

For example: `"hell\rope\r\n!"` -> `"hell", " ", "ope", " ", "!"`
*/
header_value_iterator :: proc(value: ^string) -> (part: string, ok: bool) {
	if len(value) == 0 {
		return
	}

	i, _ := #force_inline strings.index_multi(value^, {"\r", "\n"})
	switch i {
	case -1:
		part   = value^
		value^ = ""
	case 0:
		part   = " "
		value^ = value[1:]
	case:
		part   = value[:i]
		value^ = value[i:]
	}

	ok = true
	return
}

_HEADERS_ARE_READONLY :: proc(h: Headers) -> bool {
	return h.threshold < 0
}

_headers_set_readonly :: proc(h: ^Headers) {
	if h.threshold > 0 { h.threshold = -h.threshold }
}

_headers_set_writable :: proc(h: ^Headers) {
	if h.threshold < 0 { h.threshold = -h.threshold }
}

_headers_set_with_hash :: proc(m: ^Headers, entry: Header_Spot) -> mem.Allocator_Error #no_bounds_check {
	if m.len >= m.threshold {
		_headers_grow(m) or_return
	}

	mask := u64(len(m.spots) - 1)
	idx  := entry.hash & mask
	for {
		candidate := &m.spots[idx]

		if candidate.hash == 0 || (candidate.hash == entry.hash && _headers_eq(candidate.key, entry.key)) {
			if candidate.hash == 0 {
				m.len += 1
			}

			candidate^ = entry 
			return nil
		}

		idx = (idx + 1) & mask
	}
}

_headers_add_with_hash :: proc(m: ^Headers, entry: Header_Spot) -> mem.Allocator_Error #no_bounds_check {
	if m.len >= m.threshold {
		_headers_grow(m) or_return
	}

	mask := u64(len(m.spots) - 1)
	idx  := entry.hash & mask
	for {
		candidate := &m.spots[idx]

		if candidate.hash == 0 {
			m.len += 1
			candidate^ = entry 
			return nil
		}

		idx = (idx + 1) & mask
	}
}

_headers_get_with_hash :: proc(m: Headers, key: string, hashed: u64) -> (value: string, ok: bool) #optional_ok {
	spot := _headers_spot_with_hash(m, key, hashed)
	if spot == nil { return }
	return spot.value, true
}

_headers_has_with_hash :: proc(m: Headers, key: string, hashed: u64) -> bool {
	_, has := #force_inline _headers_get_with_hash(m, key, hashed)
	return has
}

_headers_delete_with_hash :: proc(m: Headers, key: string, hashed: u64) -> (deleted_key, deleted_value: string) #no_bounds_check {
	spot := _headers_spot_with_hash(m, key, hashed)
	if spot == nil { return }
	spot.hash = 0
	deleted_key   = spot.key
	deleted_value = spot.value
	return
}

_headers_spot :: proc(m: Headers, key: string) -> ^Header_Spot {
	hashed := _headers_hash_key(key)
	return #force_inline _headers_spot_with_hash(m, key, hashed)
}

_headers_spot_with_hash :: proc(m: Headers, key: string, hashed: u64) -> ^Header_Spot #no_bounds_check {
	if m.len == 0 { return nil }

	mask := u64(len(m.spots) - 1)
	idx  := hashed & mask

	for {
		entry := &m.spots[idx]
		if entry.hash == 0 { return nil }

		if entry.hash == hashed && _headers_eq(key, entry.key) {
			return entry
		}

		idx = (idx + 1) & mask
	}
}

_headers_grow :: proc(m: ^Headers) -> mem.Allocator_Error {
	nm: Headers
	nm.allocator = m.allocator.procedure == nil ? context.allocator : m.allocator

	nm.spots = make([]Header_Spot, max(len(m.spots)*2, INITIAL_CAP), nm.allocator) or_return
	nm.threshold = int(f32(len(nm.spots)) * f32(LOAD_FACTOR))

	for spot in m.spots {
		if spot.hash != 0 {
			_headers_add_with_hash(&nm, spot)
		}
	}

	delete(m.spots, m.allocator)

	m^ = nm
	return nil
}

_headers_hash_key :: proc(header: string) -> (res: u64) #no_bounds_check {
	// siphash modified to ascii lowercase and never return 0.

	CROUNDS :: 2
	DROUNDS :: 4

	ROTL :: #force_inline proc "contextless" (x, b: u64) -> u64 {
		return (x << b) | (x >> (64 - b))
	}

	U8TO64_LE :: endian.unchecked_get_u64le

	v0 := u64(0x736f6d6570736575)
	v1 := u64(0x646f72616e646f6d)
	v2 := u64(0x6c7967656e657261)
	v3 := u64(0x7465646279746573)
	k0 := U8TO64_LE(SECRET[:])
	k1 := U8TO64_LE(SECRET[8:])

	v3 ~= k1
	v2 ~= k0
	v1 ~= k1
	v0 ~= k0

	ni   := transmute([]byte)header
	left := len(ni) & 7
	b    := u64(len(ni)) << 56
	for ; len(ni) >= size_of(u64); ni = ni[size_of(u64):] {
		m := ASCII_LOWER_U64(U8TO64_LE(ni))
		v3 ~= m

		for _ in 0..<CROUNDS {
			v0 += v1
			v1 = ROTL(v1, 13)
			v1 ~= v0
			v0 = ROTL(v0, 32)
			v2 += v3
			v3 = ROTL(v3, 16)
			v3 ~= v2
			v0 += v3
			v3 = ROTL(v3, 21)
			v3 ~= v0
			v2 += v1
			v1 = ROTL(v1, 17)
			v1 ~= v2
			v2 = ROTL(v2, 32)
		}

		v0 ~= m
	}

	switch left {
	case 7:
		b |= u64(ASCII_LOWER_U8(ni[6])) << 48
		fallthrough
	case 6:
		b |= u64(ASCII_LOWER_U8(ni[5])) << 40
		fallthrough
	case 5:
		b |= u64(ASCII_LOWER_U8(ni[4])) << 32
		fallthrough
	case 4:
		b |= u64(ASCII_LOWER_U8(ni[3])) << 24
		fallthrough
	case 3:
		b |= u64(ASCII_LOWER_U8(ni[2])) << 16
		fallthrough
	case 2:
		b |= u64(ASCII_LOWER_U8(ni[1])) << 8
		fallthrough
	case 1:
		b |= u64(ASCII_LOWER_U8(ni[0]))
	}

	v3 ~= b

	for _ in 0..<CROUNDS {
		v0 += v1
		v1 = ROTL(v1, 13)
		v1 ~= v0
		v0 = ROTL(v0, 32)
		v2 += v3
		v3 = ROTL(v3, 16)
		v3 ~= v2
		v0 += v3
		v3 = ROTL(v3, 21)
		v3 ~= v0
		v2 += v1
		v1 = ROTL(v1, 17)
		v1 ~= v2
		v2 = ROTL(v2, 32)
	}

	v0 ~= b
	v2 ~= 0xff

	for _ in 0..<DROUNDS {
		v0 += v1
		v1 = ROTL(v1, 13)
		v1 ~= v0
		v0 = ROTL(v0, 32)
		v2 += v3
		v3 = ROTL(v3, 16)
		v3 ~= v2
		v0 += v3
		v3 = ROTL(v3, 21)
		v3 ~= v0
		v2 += v1
		v1 = ROTL(v1, 17)
		v1 ~= v2
		v2 = ROTL(v2, 32)
	}

	b = v0 ~ v1 ~ v2 ~ v3
	return max(1, b)
}

_headers_eq :: proc(a, b: string) -> bool #no_bounds_check {
	(len(a) == len(b)) or_return

	i: int
	for ; i + size_of(u64) <= len(a); i += size_of(u64) {
		ac := ASCII_LOWER_U64(intrinsics.unaligned_load((^u64)(raw_data(a[i:]))))
		bc := ASCII_LOWER_U64(intrinsics.unaligned_load((^u64)(raw_data(b[i:]))))
		(ac == bc) or_return
	}

	for j in i ..< len(a) {
		ac := ASCII_LOWER_U8(a[j])
		bc := ASCII_LOWER_U8(b[j])
		(ac == bc) or_return
	}

	return true
}

@(private="file")
SECRET: [16]byte

// TODO: no init
@(private="file", init)
init_secret :: proc "contextless" () {
	runtime.rand_bytes(SECRET[:])
}

@(private="file")
ASCII_LOWER_U64 :: #force_inline proc "contextless" (x: u64) -> u64 {
	mask := ((x + 0x3f3f3f3f3f3f3f3f) ~ (x + 0x2525252525252525)) & 0x8080808080808080
	return x | (mask >> 2)
}

@(private="file")
ASCII_LOWER_U8 :: #force_inline proc "contextless" (x: u8) -> u8 {
	return x | (u8(x >= 'A' && x <= 'Z') << 5)
}

@(private="file")
TOKEN_SET: strings.Ascii_Set

// TODO: no init
@(init, private)
init_token_set :: proc "contextless" () {
	ok: bool
	TOKEN_SET, ok = strings.ascii_set_make("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
	assert_contextless(ok)
}
