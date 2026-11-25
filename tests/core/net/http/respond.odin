package test_core_net_http

import "core:encoding/json"
import "core:strings"
import "core:testing"

import http "core:http2"

@(test)
test_resolve_dir_path_and_respond_file_content :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env, with_connections = true)
	defer test_env_destroy(&env)

	// 1. Valid path resolutions.
	{
		c := test_conn_push(t, &env)
		defer http._connection_destroy(c)
		tx_alloc := http.transaction_allocator(c)

		Valid_Case :: struct {
			target:   string,
			path:     string,
			expected: string,
			redirect: bool,
		}
		valid := []Valid_Case{
			{"public",   "/js/app.js",       "public/js/app.js",       false},
			{"./public", "/js/app.js",       "public/js/app.js",       false},
			{"public",   "/hello world.txt", "public/hello world.txt", false},
			{"public",   "",                 "",                       true},
			{"public",   "/",                "public/index.html",      false},
			{"public",   "/sub/",            "public/sub/index.html",  false},
			{"public",   "/about.html",      "public/about.html",      false},
			{".",        "/README.md",       "README.md",              false},
			{"",         "/sub/file.txt",    "sub/file.txt",           false},
		}
		for tc in valid {
			resolved, redirect, ok := http._resolve_dir_path(tc.target, tc.path, tx_alloc)
			testing.expectf(t, ok, "expected _resolve_dir_path(%q, %q) to succeed", tc.target, tc.path)
			testing.expect_value(t, redirect, tc.redirect)
			testing.expect_value(t, resolved, tc.expected)
		}

		// 2. Rejected traversal / malformed paths.
		invalid := [][2]string{
			{"public", "/../secret"},
			{"public", "/a/../b.txt"},
			{"public", "/sub/."},
			{"public", "/sub/a/.."},
			{"public", "/a/../../secret"},
			{"public", "//a.txt"},
			{"public", "/sub//"},
			{"public", "/a\\b"},
			{"public", "/a\x00.txt"},
			{"public", "/a\n.txt"},
			{"public", "/a\x7f.txt"},
			{"public", "/C:/win"},
			{"public", "no-leading-slash"},
		}
		for tc in invalid {
			resolved, _, ok := http._resolve_dir_path(tc[0], tc[1], tx_alloc)
			testing.expectf(t, !ok, "expected _resolve_dir_path(%q, %q) to fail, got %q", tc[0], tc[1], resolved)
		}
	}

	// 3. respond_file_content sets Content-Type from extension when unset.
	{
		c := test_conn_push(t, &env, mock_handling = true)
		defer test_conn_destroy_pooled(c)

		http.respond_file_content(&c.ctx, "assets/data.json", transmute([]byte)string(`{"ok":true}`))
		ct, has_ct := http.headers_get(c.res.headers, "content-type")
		testing.expect(t, has_ct)
		testing.expect_value(t, ct, "application/json")
	}

	// 4. respond_file_content preserves existing Content-Type.
	{
		c := test_conn_push(t, &env, mock_handling = true)
		defer test_conn_destroy_pooled(c)

		http.set_header(&c.ctx, "Content-Type", "application/vnd.custom+json")
		http.respond_file_content(&c.ctx, "assets/data.json", transmute([]byte)string(`{}`))
		ct, has_ct := http.headers_get(c.res.headers, "content-type")
		testing.expect(t, has_ct)
		testing.expect_value(t, ct, "application/vnd.custom+json")
	}

	// 5. respond_file_content omits Content-Type when extension is unknown.
	{
		c := test_conn_push(t, &env, mock_handling = true)
		defer test_conn_destroy_pooled(c)

		http.respond_file_content(&c.ctx, "LICENSE", transmute([]byte)string("MIT"))
		_, has_ct := http.headers_get(c.res.headers, "content-type")
		testing.expect(t, !has_ct)
	}
}

@(test)
test_respond_helpers_and_send_chunk :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env, with_connections = true)
	defer test_env_destroy(&env)

	// 1. respond_plain sets Content-Type: text/plain and Content-Length.
	{
		c := test_conn_push(t, &env, mock_handling = true)
		defer test_conn_destroy_pooled(c)

		http.respond_plain(&c.ctx, "hello world")
		ct, has_ct := http.headers_get(c.res.headers, "content-type")
		testing.expect(t, has_ct)
		testing.expect_value(t, ct, "text/plain")
		testing.expect(t, strings.contains(string(c.res._buf[:]), "Content-Length: 11\r\n"), "expected Content-Length: 11")
	}

	// 2. respond_html sets Content-Type: text/html and preserves pre-set Content-Type.
	{
		c := test_conn_push(t, &env, mock_handling = true)
		defer test_conn_destroy_pooled(c)

		http.respond_html(&c.ctx, "<p>hi</p>")
		ct, has_ct := http.headers_get(c.res.headers, "content-type")
		testing.expect(t, has_ct)
		testing.expect_value(t, ct, "text/html")
		testing.expect(t, strings.contains(string(c.res._buf[:]), "Content-Length: 9\r\n"), "expected Content-Length: 9")
	}
	{
		c := test_conn_push(t, &env, mock_handling = true)
		defer test_conn_destroy_pooled(c)

		http.set_header(&c.ctx, "Content-Type", "application/xhtml+xml")
		http.respond_html(&c.ctx, "<p>hi</p>")
		ct, _ := http.headers_get(c.res.headers, "content-type")
		testing.expect_value(t, ct, "application/xhtml+xml")
	}

	// 3. respond_json sets Content-Type: application/json and Content-Length, preserves HEAD Content-Length.
	{
		Payload :: struct {
			name: string `json:"name"`,
			n:    int    `json:"n"`,
		}

		c := test_conn_push(t, &env, mock_handling = true)
		defer test_conn_destroy_pooled(c)
		c.req.line.method = .Head

		err := http.respond_json(&c.ctx, Payload{name = "odin", n = 42})
		testing.expect_value(t, err, nil)
		ct, has_ct := http.headers_get(c.res.headers, "content-type")
		testing.expect(t, has_ct)
		testing.expect_value(t, ct, "application/json")
		testing.expect(t, strings.contains(string(c.res._buf[:]), "Content-Length: 22\r\n"), "expected Content-Length: 22")
	}

	// 4. respond_json returns error cleanly before touching headers or response buffer.
	{
		c := test_conn_push(t, &env, mock_handling = true)
		defer test_conn_destroy_pooled(c)

		bad := proc() {}
		err := http.respond_json(&c.ctx, bad)
		testing.expect_value(t, err, json.Marshal_Error(json.Marshal_Data_Error.Unsupported_Type))
		testing.expect(t, c.res._state == .Handling, "expected state to remain .Handling on marshal error")
		testing.expect_value(t, len(c.res._buf), 0)
		_, has_ct := http.headers_get(c.res.headers, "content-type")
		testing.expect(t, !has_ct)
	}

	// 5. _write_chunk_header formats hex length + CRLF cleanly.
	{
		buf: [20]byte
		testing.expect_value(t, string(http._write_chunk_header(buf[:], 1)),    "1\r\n")
		testing.expect_value(t, string(http._write_chunk_header(buf[:], 15)),   "f\r\n")
		testing.expect_value(t, string(http._write_chunk_header(buf[:], 255)),  "ff\r\n")
		testing.expect_value(t, string(http._write_chunk_header(buf[:], 4096)), "1000\r\n")
	}

	// 6. send_chunk sets Transfer-Encoding: chunked without Content-Length when writing headers.
	{
		c := test_conn_push(t, &env, mock_handling = true)
		defer test_conn_destroy_pooled(c)

		http.send_chunk(&c.ctx, {transmute([]byte)string("hi!")})
		te, has_te := http.headers_get(c.res.headers, "transfer-encoding")
		testing.expect(t, has_te)
		testing.expect_value(t, te, "chunked")
		testing.expect(t, strings.contains(string(c.res._buf[:]), "Transfer-Encoding: chunked\r\n"), "expected Transfer-Encoding: chunked")
		testing.expect(t, !strings.contains(string(c.res._buf[:]), "Content-Length:"), "unexpected Content-Length in chunked response")
	}
}

@(test)
test_constraint_bufs :: proc(t: ^testing.T) {
	backing: [128]byte

	Case :: struct {
		desc:  string,
		bufs:  [2][]byte,
		count: int,
		max:   int,
		want:  []int,
	}

	cases := [?]Case{
		{"single slice larger than max",      {backing[:100], nil},             1, 80, {80}},
		{"exact boundary drops second slice", {backing[:50], backing[50:100]},  2, 50, {50}},
		{"truncates into first slice",        {backing[:50], backing[50:100]},  2, 30, {30}},
		{"partial trim of second slice",      {backing[:50], backing[50:100]},  2, 70, {50, 20}},
		{"trailing nil slice dropped",        {backing[:100], nil},             2, 80, {80}},
		{"no-op when total <= max",           {backing[:40], backing[40:60]},   2, 60, {40, 20}},
	}

	for &tc in cases {
		out := http._constraint_bufs(tc.bufs[:tc.count], tc.max)
		testing.expectf(t, len(out) == len(tc.want), "%s: expected %d slices, got %d", tc.desc, len(tc.want), len(out))
		for i in 0 ..< min(len(out), len(tc.want)) {
			testing.expect_value(t, len(out[i]), tc.want[i])
		}
	}
}
