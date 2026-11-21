package test_core_net_http

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

import http "core:http2"

@(init)
init_test_hash_secret :: proc "contextless" () {
	http.headers_init_hash_secret()
}

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
test_requestline_and_header_parse_validation :: proc(t: ^testing.T) {
	// Valid request lines.
	{
		rl, err := http.requestline_parse("GET /path?a=1 HTTP/1.1")
		testing.expect_value(t, err, http.Requestline_Error.None)
		testing.expect_value(t, rl.method, http.Method.Get)
		testing.expect_value(t, rl.target, "/path?a=1")
		testing.expect_value(t, rl.version, http.Version{1, 1})
	}
	{
		rl, err := http.requestline_parse("POST / HTTP/1.0")
		testing.expect_value(t, err, http.Requestline_Error.None)
		testing.expect_value(t, rl.method, http.Method.Post)
		testing.expect_value(t, rl.target, "/")
		testing.expect_value(t, rl.version, http.Version{1, 0})
	}

	// Reject malformed request-targets (empty, whitespace, bare CR/LF, NUL, CTL, DEL).
	bad_targets := []string{
		"GET  HTTP/1.1",
		"GET /a\rb HTTP/1.1",
		"GET /a\nb HTTP/1.1",
		"GET /a\x00b HTTP/1.1",
		"GET /a\tb HTTP/1.1",
		"GET /a\x07b HTTP/1.1",
		"GET /a\x7fb HTTP/1.1",
	}
	for raw in bad_targets {
		_, err := http.requestline_parse(raw)
		testing.expectf(t, err == .Invalid_Target, "expected .Invalid_Target for %q, got %v", raw, err)
	}

	// Reject non-digit or malformed HTTP versions.
	bad_versions := []string{
		"GET / HTTP/1.\r",
		"GET / HTTP/a.1",
		"GET / HTTP/1.a",
		"GET / HTTP/1.",
		"GET / HTTP/1.12",
		"GET / HTTX/1.1",
		"GET / HTTP/1.1\n",
	}
	for raw in bad_versions {
		_, err := http.requestline_parse(raw)
		testing.expectf(t, err == .Invalid_Version_Format, "expected .Invalid_Version_Format for %q, got %v", raw, err)
	}

	// Valid headers: OWS (' ' and '\t') trimmed at edges, internal HTAB and obs-text permitted.
	{
		k, v, ok := http.header_parse("Host: example.com")
		testing.expect(t, ok)
		testing.expect_value(t, k, "Host")
		testing.expect_value(t, v, "example.com")
	}
	{
		k, v, ok := http.header_parse("X-Tab: \ta\tb \t")
		testing.expect(t, ok)
		testing.expect_value(t, k, "X-Tab")
		testing.expect_value(t, v, "a\tb")
	}
	{
		k, v, ok := http.header_parse("X-Empty: \t ")
		testing.expect(t, ok)
		testing.expect_value(t, k, "X-Empty")
		testing.expect_value(t, v, "")
	}
	{
		k, v, ok := http.header_parse("X-Obs: caf\xc3\xa9")
		testing.expect(t, ok)
		testing.expect_value(t, k, "X-Obs")
		testing.expect_value(t, v, "caf\xc3\xa9")
	}

	// Invalid header names & values (non-token key, spaces around colon, CTLs, NUL, bare CR/LF).
	bad_headers := []string{
		": val",
		" Host: localhost",
		"Host : localhost",
		"Bad Key: val",
		"Bad\rKey: val",
		"Bad\x00Key: val",
		"X-Test: a\rb",
		"X-Test: a\nb",
		"X-Test: \ra",
		"X-Test: a\n",
		"X-Test: a\x00b",
		"X-Test: a\x07b",
		"X-Test: a\vb",
		"X-Test: a\fb",
		"X-Test: a\x7fb",
	}
	for raw in bad_headers {
		_, _, ok := http.header_parse(raw)
		testing.expectf(t, !ok, "expected header_parse(%q) to fail", raw)
	}
}

@(test)
test_set_cookie_and_heading_serialization :: proc(t: ^testing.T) {
	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	c := push_test_connection(t, &env)
	defer http.connection_destroy(c)

	c.req.line.version      = {1, 1}
	c.req.has_consumed_body = true
	c.res.status            = .OK

	expires, ok := time.datetime_to_time(2026, 11, 21, 15, 30, 0)
	testing.expect(t, ok, "expected valid datetime")

	http.set_cookie(&c.res, {
		name  = "session",
		value = "abc123",
	})
	http.set_cookie(&c.res, {
		name         = "prefs",
		value        = "dark\r\nmode",
		domain       = "example.com",
		path         = "/app",
		expires_gmt  = expires,
		max_age_secs = 3600,
		same_site    = .Lax,
		secure       = true,
		partitioned  = true,
		http_only    = true,
	})
	http.set_cookie(&c.res, {
		name      = "strict_tok",
		value     = "s",
		same_site = .Strict,
	})
	http.set_cookie(&c.res, {
		name      = "cross_tok",
		value     = "n",
		same_site = .None,
		secure    = true,
	})

	values := make([dynamic]string, context.allocator)
	defer delete(values)
	iter := http.headers_get_all_iterator(&c.res.headers, "set-cookie")
	for v in http.headers_get_all_iter(&iter) {
		append(&values, v)
	}

	testing.expect_value(t, len(values), 4)
	testing.expect_value(t, values[0], "session=abc123")
	testing.expect_value(t, values[1], "prefs=dark\r\nmode; Domain=example.com; Expires=Sat, 21 Nov 2026 15:30:00 GMT; Max-Age=3600; Path=/app; SameSite=Lax; Secure; Partitioned; HttpOnly")
	testing.expect_value(t, values[2], "strict_tok=s; SameSite=Strict")
	testing.expect_value(t, values[3], "cross_tok=n; SameSite=None; Secure")

	http.write_response_heading(&c.res)
	heading := string(c.res.buf[:])
	testing.expect(t, strings.contains(heading, "Set-Cookie: session=abc123\r\n"), "expected first Set-Cookie header line")
	testing.expect(t, strings.contains(heading, "Set-Cookie: prefs=dark  mode; Domain=example.com; Expires=Sat, 21 Nov 2026 15:30:00 GMT; Max-Age=3600; Path=/app; SameSite=Lax; Secure; Partitioned; HttpOnly\r\n"), "expected escaped second Set-Cookie header line")
	testing.expect(t, strings.contains(heading, "Set-Cookie: strict_tok=s; SameSite=Strict\r\n"), "expected strict Set-Cookie header line")
	testing.expect(t, strings.contains(heading, "Set-Cookie: cross_tok=n; SameSite=None; Secure\r\n"), "expected none Set-Cookie header line")
}

@(test)
test_mime_from_extension_and_content_type :: proc(t: ^testing.T) {
	Known_Case :: struct {
		input:        string,
		mime:         http.Mime_Type,
		content_type: string,
	}

	known := []Known_Case{
		{"notes.txt",        .Plain,       "text/plain"},
		{"dir/index.html",   .Html,        "text/html"},
		{"dir/page.htm",     .Html,        "text/html"},
		{"app.js",           .Js,          "application/javascript"},
		{"mod.mjs",          .Js,          "application/javascript"},
		{"style.css",        .Css,         "text/css"},
		{"data.csv",         .Csv,         "text/csv"},
		{"feed.xml",         .Xml,         "text/xml"},
		{"archive.zip",      .Zip,         "application/zip"},
		{"api.json",         .Json,        "application/json"},
		{"favicon.ico",      .Ico,         "application/vnd.microsoft.ico"},
		{"anim.gif",         .Gif,         "image/gif"},
		{"photo.jpeg",       .Jpeg,        "image/jpeg"},
		{"photo.jpg",        .Jpeg,        "image/jpeg"},
		{"img.png",          .Png,         "image/png"},
		{"icon.svg",         .Svg,         "image/svg+xml"},
		{"main.wasm",        .Wasm,        "application/wasm"},
		{"README.md",        .Md,          "text/markdown"},
		{"html",             .Html,        "text/html"},
		{".html",            .Html,        "text/html"},
	}

	for tc in known {
		mime, ok := http.mime_from_extension(tc.input)
		testing.expectf(t, ok, "expected mime_from_extension(%q) to succeed", tc.input)
		testing.expect_value(t, mime, tc.mime)
		testing.expect_value(t, http.mime_to_content_type(mime), tc.content_type)
	}

	testing.expect_value(t, http.mime_to_content_type(.Url_Encoded), "application/x-www-form-urlencoded")

	unknown := []string{
		"",
		"LICENSE",
		"dir/Makefile",
		"dir/html",
		".gitignore",
		"file.bin",
		"archive.tar.gz",
	}
	for input in unknown {
		_, ok := http.mime_from_extension(input)
		testing.expectf(t, !ok, "expected mime_from_extension(%q) to return false", input)
	}
}
