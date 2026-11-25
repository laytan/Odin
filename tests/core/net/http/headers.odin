package test_core_net_http

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

import http "core:http2"

@(test)
test_header_value_iterator :: proc(t: ^testing.T) {
	cases := [][]string{
		{"hell\rope\r\n!", "hell", " ", "ope", " ", " ", "!"},
		{"hellope!", "hellope!"},
		{"", ""},
	}
	for tcase in cases {
		i := 1
		input := tcase[0]
		for part in http.header_value_iterator(&input) {
			testing.expect_value(t, part, tcase[i])
			i += 1
		}
	}
}

@(test)
test_headers_delete_backward_shift_preserves_probe_chain :: proc(t: ^testing.T) {
	h := http._headers_make(context.allocator)
	defer http.headers_destroy(h)

	// Deleting from empty headers must be a safe no-op.
	dk, dv := http.headers_delete(&h, "missing")
	testing.expect_value(t, dk, "")
	testing.expect_value(t, dv, "")

	mask := u64(http.INITIAL_CAP - 1)
	bucket15_keys: [3]string
	b15_count := 0
	bucket0_key := ""

	for i := 0; b15_count < len(bucket15_keys) || bucket0_key == ""; i += 1 {
		key := fmt.tprintf("x-probe-%d", i)
		bucket := http._headers_hash_key(key) & mask
		if bucket == 15 && b15_count < len(bucket15_keys) {
			bucket15_keys[b15_count] = key
			b15_count += 1
		} else if bucket == 0 && bucket0_key == "" {
			bucket0_key = key
		}
	}

	// Layout in 16-slot table:
	// slot 15: bucket15_keys[0] (home 15)
	// slot 0:  bucket0_key      (home 0)
	// slot 1:  bucket15_keys[1] (home 15, displaced past slot 0)
	// slot 2:  bucket15_keys[2] (home 15, displaced past slot 1)
	testing.expect_value(t, http.headers_add(&h, bucket15_keys[0], "v0"), nil)
	testing.expect_value(t, http.headers_add(&h, bucket0_key, "m0"), nil)
	testing.expect_value(t, http.headers_add(&h, bucket15_keys[1], "v1"), nil)
	testing.expect_value(t, http.headers_add(&h, bucket15_keys[2], "v2"), nil)
	testing.expect_value(t, http.headers_len(h), 4)

	del_k, del_v := http.headers_delete(&h, bucket15_keys[0])
	testing.expect_value(t, del_k, bucket15_keys[0])
	testing.expect_value(t, del_v, "v0")
	testing.expect_value(t, http.headers_len(h), 3)

	_, has_deleted := http.headers_get(h, bucket15_keys[0])
	testing.expect(t, !has_deleted, "deleted key should no longer be present")

	v_m0, ok_m0 := http.headers_get(h, bucket0_key)
	testing.expect(t, ok_m0, "intervening home-slot key should remain reachable")
	testing.expect_value(t, v_m0, "m0")

	v1, ok1 := http.headers_get(h, bucket15_keys[1])
	testing.expect(t, ok1, "first displaced probe entry should remain reachable")
	testing.expect_value(t, v1, "v1")

	v2, ok2 := http.headers_get(h, bucket15_keys[2])
	testing.expect(t, ok2, "second displaced probe entry should remain reachable")
	testing.expect_value(t, v2, "v2")

	// Deleting the intervening home-slot key must also preserve the rest of the cluster.
	_, _ = http.headers_delete(&h, bucket0_key)
	testing.expect_value(t, http.headers_len(h), 2)
	_, ok_m0_after := http.headers_get(h, bucket0_key)
	testing.expect(t, !ok_m0_after, "deleted home-slot key should no longer be present")

	v1_after, ok1_after := http.headers_get(h, bucket15_keys[1])
	testing.expect(t, ok1_after && v1_after == "v1", "expected v1 after deleting bucket0_key")
	v2_after, ok2_after := http.headers_get(h, bucket15_keys[2])
	testing.expect(t, ok2_after && v2_after == "v2", "expected v2 after deleting bucket0_key")
}

@(test)
test_headers_delete_removes_all_multi_value_entries :: proc(t: ^testing.T) {
	h := http._headers_make(context.allocator)
	defer http.headers_destroy(h)

	testing.expect_value(t, http.headers_add(&h, "Set-Cookie", "a=1"), nil)
	testing.expect_value(t, http.headers_add(&h, "X-Keep", "keep-val"), nil)
	testing.expect_value(t, http.headers_add(&h, "set-cookie", "b=2"), nil)
	testing.expect_value(t, http.headers_add(&h, "SET-COOKIE", "c=3"), nil)
	testing.expect_value(t, http.headers_len(h), 4)

	del_k, del_v := http.headers_delete(&h, "set-cookie")
	testing.expect_value(t, del_k, "Set-Cookie")
	testing.expect_value(t, del_v, "a=1")
	testing.expect_value(t, http.headers_len(h), 1)
	testing.expect(t, !http.headers_has(h, "set-cookie"), "expected all Set-Cookie variants to be deleted")

	iter := http.headers_get_all_iterator(&h, "set-cookie")
	count := 0
	for _ in http.headers_get_all_iter(&iter) {
		count += 1
	}
	testing.expect_value(t, count, 0)

	keep, keep_ok := http.headers_get(h, "x-keep")
	testing.expect(t, keep_ok, "unrelated header should remain")
	testing.expect_value(t, keep, "keep-val")
}

@(test)
test_headers_has_token :: proc(t: ^testing.T) {
	empty: http.Headers
	testing.expect(t, !http.headers_has_token(&empty, "connection", "close"))

	h := http._headers_make(context.allocator)
	defer http.headers_destroy(h)

	// Single exact match (case-insensitive header name and token value).
	testing.expect_value(t, http.headers_set(&h, "Connection", "CLOSE"), nil)
	testing.expect(t, http.headers_has_token(&h, "connection", "close"))
	testing.expect(t, !http.headers_has_token(&h, "connection", "close2"))
	testing.expect(t, !http.headers_has_token(&h, "connection", "myclose"))
	testing.expect(t, !http.headers_has_token(&h, "connection", ""))

	// Multi-token comma-separated list with spaces and tabs.
	testing.expect_value(t, http.headers_set(&h, "Connection", "keep-alive, \t Upgrade "), nil)
	testing.expect(t, http.headers_has_token(&h, "connection", "keep-alive"))
	testing.expect(t, http.headers_has_token(&h, "connection", "upgrade"))
	testing.expect(t, !http.headers_has_token(&h, "connection", "up"))
	testing.expect(t, !http.headers_has_token(&h, "connection", "close"))

	// Repeated header entries.
	h2 := http._headers_make(context.allocator)
	defer http.headers_destroy(h2)
	testing.expect_value(t, http.headers_add(&h2, "Connection", "keep-alive"), nil)
	testing.expect_value(t, http.headers_add(&h2, "connection", "Upgrade"), nil)
	testing.expect(t, http.headers_has_token(&h2, "Connection", "keep-alive"))
	testing.expect(t, http.headers_has_token(&h2, "Connection", "upgrade"))
	testing.expect(t, !http.headers_has_token(&h2, "Connection", "close"))
}

@(test)
test_headers_valid_key :: proc(t: ^testing.T) {
	expected, ok := strings.ascii_set_make("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
	testing.expect(t, ok, "expected ASCII token set construction to succeed")

	testing.expect(t, !http.headers_valid_key(""), "expected empty header key to be invalid")

	for c in 0..=255 {
		b := [1]byte{u8(c)}
		s := string(b[:])
		testing.expectf(
			t,
			http.headers_valid_key(s) == strings.ascii_set_contains(expected, u8(c)),
			"mismatch for byte 0x%02x",
			c,
		)
	}

	testing.expect(t, http.headers_valid_key("Content-Type"))
	testing.expect(t, http.headers_valid_key("X-Custom_Header.1"))
	testing.expect(t, !http.headers_valid_key("Bad Header"))
	testing.expect(t, !http.headers_valid_key("Bad:Header"))
	testing.expect(t, !http.headers_valid_key("Bad\r\nHeader"))
}

@(test)
test_headers_allocator_errors_and_readonly :: proc(t: ^testing.T) {
	// 1. Initial grow OOM propagates cleanly across headers_set, headers_add, and headers_entry.
	{
		tiny_buf: [1]byte
		tiny_arena: mem.Arena
		mem.arena_init(&tiny_arena, tiny_buf[:])
		h := http._headers_make(mem.arena_allocator(&tiny_arena))

		testing.expect_value(t, http.headers_set(&h, "Host", "example.com"), mem.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, http.headers_add(&h, "Host", "example.com"), mem.Allocator_Error.Out_Of_Memory)

		kp, vp, ins, err := http.headers_entry(&h, "Host")
		testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
		testing.expect(t, kp == nil && vp == nil && !ins, "expected nil entry outputs on OOM")
		testing.expect_value(t, http.headers_len(h), 0)
		testing.expect(t, h.spots == nil, "expected spots slice to remain nil on initial OOM")
	}

	// 2. Rehash grow OOM propagates and preserves all existing entries.
	{
		buf: [size_of(http.Header_Spot) * http.INITIAL_CAP + 64]byte
		a: mem.Arena
		mem.arena_init(&a, buf[:])
		h := http._headers_make(mem.arena_allocator(&a))

		keys := [11]string{
			"X-H-0", "X-H-1", "X-H-2", "X-H-3", "X-H-4", "X-H-5",
			"X-H-6", "X-H-7", "X-H-8", "X-H-9", "X-H-10",
		}
		for k in keys {
			testing.expect_value(t, http.headers_add(&h, k, "v"), nil)
		}
		testing.expect_value(t, http.headers_len(h), 11)
		testing.expect_value(t, h.threshold, 11)

		testing.expect_value(t, http.headers_set(&h, "X-H-Overflow", "x"), mem.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, http.headers_add(&h, "X-H-Overflow", "x"), mem.Allocator_Error.Out_Of_Memory)

		kp, vp, ins, err := http.headers_entry(&h, "X-H-Overflow")
		testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
		testing.expect(t, kp == nil && vp == nil && !ins, "expected nil entry outputs on rehash OOM")
		testing.expect_value(t, http.headers_len(h), 11)

		for k in keys {
			v, ok := http.headers_get(h, k)
			testing.expect(t, ok, "expected existing key to remain present after rehash OOM")
			testing.expect_value(t, v, "v")
		}
	}

	// 3. Readonly toggling works idempotently on both empty and populated Headers.
	{
		empty: http.Headers
		testing.expect(t, !http._HEADERS_ARE_READONLY(empty), "expected fresh Headers to be writable")

		http._headers_set_readonly(&empty)
		http._headers_set_readonly(&empty)
		testing.expect(t, http._HEADERS_ARE_READONLY(empty), "expected empty Headers to be marked readonly")

		http._headers_set_writable(&empty)
		http._headers_set_writable(&empty)
		testing.expect(t, !http._HEADERS_ARE_READONLY(empty), "expected empty Headers to be writable again")
		testing.expect_value(t, empty.threshold, 0)

		empty.allocator = context.allocator
		defer http.headers_destroy(empty)
		testing.expect_value(t, http.headers_set(&empty, "X-Ok", "1"), nil)
		v_ok, has_ok := http.headers_get(empty, "x-ok")
		testing.expect(t, has_ok && v_ok == "1", "expected writable empty Headers to accept inserts")

		http._headers_set_readonly(&empty)
		http._headers_set_readonly(&empty)
		testing.expect(t, http._HEADERS_ARE_READONLY(empty), "expected populated Headers to be marked readonly")

		http._headers_set_writable(&empty)
		http._headers_set_writable(&empty)
		testing.expect(t, !http._HEADERS_ARE_READONLY(empty), "expected populated Headers to be writable again")

		kp, vp, ins, err := http.headers_entry(&empty, "X-Entry")
		testing.expect_value(t, err, nil)
		testing.expect(t, ins && kp^ == "X-Entry", "expected new entry key populated")
		vp^ = "val"
		v_ent, has_ent := http.headers_get(empty, "x-entry")
		testing.expect(t, has_ent && v_ent == "val", "expected inserted entry value to be readable")
	}
}
