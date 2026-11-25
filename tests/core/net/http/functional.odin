#+build windows, linux, darwin
package test_core_net_http

import "base:runtime"

import c "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import http "core:http2"
import "vendor:curl"

@(init, private="file")
_curl_init :: proc "contextless" () {
	curl.global_init(curl.GLOBAL_ALL)
}

Curl_Method :: enum {
	Get,
	Head,
	Post,
}

Curl_Request :: struct {
	method:     Curl_Method,
	headers:    []string,
	body:       []byte,
	path_as_is: bool,
}

Curl_Result :: struct {
	setopt_ok:      bool,
	perform_err:    curl.code,
	getinfo_err:    curl.code,
	status:         int,
	content_length: i64,
	raw_headers:    [dynamic]byte,
	body:           [dynamic]byte,
}

curl_write_buf :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
	context = runtime.default_context()
	buf := (^[dynamic]byte)(userp)
	real_size := int(size) * int(nmemb)
	old_len := len(buf)
	resize(buf, old_len + real_size)
	copy(buf[old_len:], contents[:real_size])
	return c.size_t(real_size)
}

curl_request :: proc(handle: ^curl.CURL, port: int, path: string, req: Curl_Request = {}) -> (res: Curl_Result) {
	curl.easy_reset(handle)

	url := fmt.ctprintf("http://127.0.0.1:%d%s", port, path)
	ok := curl.easy_setopt(handle, .URL, url) == .E_OK &&
		curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_buf) == .E_OK &&
		curl.easy_setopt(handle, .WRITEDATA, &res.body) == .E_OK &&
		curl.easy_setopt(handle, .HEADERFUNCTION, curl_write_buf) == .E_OK &&
		curl.easy_setopt(handle, .HEADERDATA, &res.raw_headers) == .E_OK

	if req.path_as_is {
		ok = ok && curl.easy_setopt(handle, .PATH_AS_IS, c.long(1)) == .E_OK
	}

	switch req.method {
	case .Get:
		ok = ok && curl.easy_setopt(handle, .HTTPGET, c.long(1)) == .E_OK
	case .Head:
		ok = ok && curl.easy_setopt(handle, .NOBODY, c.long(1)) == .E_OK
	case .Post:
		post_ptr := rawptr(raw_data(req.body)) if len(req.body) > 0 else nil
		ok = ok &&
			curl.easy_setopt(handle, .POST, c.long(1)) == .E_OK &&
			curl.easy_setopt(handle, .POSTFIELDS, post_ptr) == .E_OK &&
			curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(len(req.body))) == .E_OK
	}

	hdrs: ^curl.slist
	defer if hdrs != nil { curl.slist_free_all(hdrs) }
	if len(req.headers) > 0 {
		for h in req.headers {
			hdrs = curl.slist_append(hdrs, strings.clone_to_cstring(h, context.temp_allocator))
		}
		ok = ok && hdrs != nil && curl.easy_setopt(handle, .HTTPHEADER, hdrs) == .E_OK
	}

	res.setopt_ok = ok
	if !ok {
		return
	}

	res.perform_err = curl.easy_perform(handle)
	status: c.long
	res.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
	res.status = int(status)
	clen: curl.off_t
	if curl.easy_getinfo(handle, .CONTENT_LENGTH_DOWNLOAD_T, &clen) == .E_OK {
		res.content_length = i64(clen)
	}
	return
}

curl_result_destroy :: proc(res: ^Curl_Result) {
	delete(res.raw_headers)
	delete(res.body)
}

curl_result_body :: proc(res: Curl_Result) -> string {
	return string(res.body[:])
}

curl_result_has_status :: proc(res: Curl_Result, prefix: string) -> bool {
	return strings.contains(string(res.raw_headers[:]), prefix)
}

curl_result_header :: proc(res: Curl_Result, key: string) -> (val: string, ok: bool) {
	rest := string(res.raw_headers[:])
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		colon := strings.index_byte(trimmed, ':')
		if colon > 0 && strings.equal_fold(trimmed[:colon], key) {
			val = strings.trim_space(trimmed[colon+1:])
			ok  = true
		}
	}
	return
}

expect_curl_ok :: proc(
	t:               ^testing.T,
	name:            string,
	res:             Curl_Result,
	expected_status: int,
	expected_body:   Maybe(string) = nil,
	loc             := #caller_location,
) {
	testing.expectf(t, res.setopt_ok, "%s: setopt failed", name, loc = loc)
	testing.expectf(t, res.perform_err == .E_OK, "%s: curl failed: %s", name, curl.easy_strerror(res.perform_err), loc = loc)
	testing.expect_value(t, res.getinfo_err, curl.code.E_OK, loc = loc)
	testing.expect_value(t, res.status, expected_status, loc = loc)
	if body, has_body := expected_body.?; has_body {
		testing.expect_value(t, curl_result_body(res), body, loc = loc)
	}
}

@(test)
test_lazy_expect_continue_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	Echo_Buf :: struct {
		data: [dynamic]byte,
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_post(&r, "/echo", proc(ctx: ^http.Ctx) {
		http.context_add(ctx, Echo_Buf{data = make([dynamic]byte, http.transaction_allocator(ctx))})
		http.body(ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {
			eb := http.context_get(ctx, Echo_Buf)
			if len(body) > 0 {
				append(&eb.data, ..body)
			}
			if !is_partial {
				http.respond_bytes(ctx, eb.data[:])
			}
		})
	})
	http.route_post(&r, "/reject", proc(ctx: ^http.Ctx) {
		ctx.res.status = .Unauthorized
		http.respond(ctx)
	})

	Client_Ctx :: struct {
		handle_ok:   bool,
		echo_ok:     Curl_Result,
		reject_401:  Curl_Result,
		too_big_413: Curl_Result,
	}
	ctx: Client_Ctx
	defer {
		curl_result_destroy(&ctx.echo_ok)
		curl_result_destroy(&ctx.reject_401)
		curl_result_destroy(&ctx.too_big_413)
	}

	_, ok := run_test_server(
		t,
		{body_limits = {max_size = 4096, min = 5 * time.Second}, handlers = {http.router(&r)}},
		&ctx,
		proc(port: int, _: ^http.Server, ctx: ^Client_Ctx) {
			handle := curl.easy_init()
			ctx.handle_ok = handle != nil
			if handle == nil { return }
			defer curl.easy_cleanup(handle)

			small_payload: [2048]byte
			for &b in small_payload { b = 'a' }
			large_payload: [8192]byte
			for &b in large_payload { b = 'b' }

			hdrs := []string{"Expect: 100-continue"}
			ctx.echo_ok     = curl_request(handle, port, "/echo",   {.Post, hdrs, small_payload[:], false})
			ctx.reject_401  = curl_request(handle, port, "/reject", {.Post, hdrs, small_payload[:], false})
			ctx.too_big_413 = curl_request(handle, port, "/echo",   {.Post, hdrs, large_payload[:], false})
		},
	)
	if !ok || !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	expected_small: [2048]byte
	for &b in expected_small { b = 'a' }

	expect_curl_ok(t, "echo_ok", ctx.echo_ok, 200, string(expected_small[:]))
	testing.expect(t, curl_result_has_status(ctx.echo_ok, "HTTP/1.1 100 Continue"), "expected POST /echo to receive 100 Continue")

	expect_curl_ok(t, "reject_401", ctx.reject_401, 401)
	testing.expect(t, !curl_result_has_status(ctx.reject_401, "HTTP/1.1 100 Continue"), "expected rejected POST /reject not to receive 100 Continue")

	expect_curl_ok(t, "too_big_413", ctx.too_big_413, 413)
	testing.expect(t, !curl_result_has_status(ctx.too_big_413, "HTTP/1.1 100 Continue"), "expected 413 POST /echo not to receive 100 Continue")
}

@(test)
test_head_requests_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	Head_Server_State :: struct {
		ping_count:         int,
		ping_methods:       [2]http.Method,
		custom_head_count:  int,
		custom_head_method: http.Method,
		custom_get_count:   int,
		custom_get_method:  http.Method,
	}
	srv_state: Head_Server_State

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ping", http.handler(&srv_state, proc(user_data: rawptr, ctx: ^http.Ctx) {
		st := (^Head_Server_State)(user_data)
		if st.ping_count < len(st.ping_methods) {
			st.ping_methods[st.ping_count] = ctx.req.line.method
		}
		st.ping_count += 1
		http.respond_bytes(ctx, transmute([]byte)string("pong"))
	}))
	http.route_head(&r, "/custom", http.handler(&srv_state, proc(user_data: rawptr, ctx: ^http.Ctx) {
		st := (^Head_Server_State)(user_data)
		st.custom_head_count += 1
		st.custom_head_method = ctx.req.line.method
		http.set_content_length_header(ctx, 9)
		http.respond(ctx)
	}))
	http.route_get(&r, "/custom", http.handler(&srv_state, proc(user_data: rawptr, ctx: ^http.Ctx) {
		st := (^Head_Server_State)(user_data)
		st.custom_get_count += 1
		st.custom_get_method = ctx.req.line.method
		http.respond_bytes(ctx, transmute([]byte)string("custom-ok"))
	}))

	Client_Ctx :: struct {
		handle_ok:   bool,
		head_ping:   Curl_Result,
		get_ping:    Curl_Result,
		head_custom: Curl_Result,
		get_custom:  Curl_Result,
	}
	ctx: Client_Ctx
	defer {
		curl_result_destroy(&ctx.head_ping)
		curl_result_destroy(&ctx.get_ping)
		curl_result_destroy(&ctx.head_custom)
		curl_result_destroy(&ctx.get_custom)
	}

	_, ok := run_test_server(t, {handlers = {http.router(&r)}}, &ctx, proc(port: int, _: ^http.Server, ctx: ^Client_Ctx) {
		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil { return }
		defer curl.easy_cleanup(handle)

		ctx.head_ping   = curl_request(handle, port, "/ping",   {method = .Head})
		ctx.get_ping    = curl_request(handle, port, "/ping",   {method = .Get})
		ctx.head_custom = curl_request(handle, port, "/custom", {method = .Head})
		ctx.get_custom  = curl_request(handle, port, "/custom", {method = .Get})
	})
	if !ok || !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	expect_curl_ok(t, "head_ping", ctx.head_ping, 200, "")
	testing.expect_value(t, ctx.head_ping.content_length, i64(4))
	expect_curl_ok(t, "get_ping", ctx.get_ping, 200, "pong")

	expect_curl_ok(t, "head_custom", ctx.head_custom, 200, "")
	testing.expect_value(t, ctx.head_custom.content_length, i64(9))
	expect_curl_ok(t, "get_custom", ctx.get_custom, 200, "custom-ok")

	testing.expect_value(t, srv_state.ping_count, 2)
	testing.expect_value(t, srv_state.ping_methods, [2]http.Method{.Head, .Get})
	testing.expect_value(t, srv_state.custom_head_count, 1)
	testing.expect_value(t, srv_state.custom_head_method, http.Method.Head)
	testing.expect_value(t, srv_state.custom_get_count, 1)
	testing.expect_value(t, srv_state.custom_get_method, http.Method.Get)
}

@(thread_local, private="file")
_tls_test_buf: []byte

@(test)
test_graceful_shutdown_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	Shutdown_Server_State :: struct {
		slow_started:    sync.One_Shot_Event,
		handler_saw_tls: bool,
	}
	srv_state: Shutdown_Server_State

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ping", proc(ctx: ^http.Ctx) {
		http.respond_bytes(ctx, transmute([]byte)string("pong"))
	})
	http.route_get(&r, "/slow", http.handler(&srv_state, proc(user_data: rawptr, ctx: ^http.Ctx) {
		st := (^Shutdown_Server_State)(user_data)
		st.handler_saw_tls = len(_tls_test_buf) >= 6 && string(_tls_test_buf[:6]) == "tls-ok"
		sync.one_shot_event_signal(&st.slow_started)
		nbio.timeout_poly(40 * time.Millisecond, ctx, proc(_: ^nbio.Operation, ctx: ^http.Ctx) {
			http.respond_bytes(ctx, transmute([]byte)string("slow-ok"))
		})
	}))

	Shutdown_Ctx :: struct {
		srv:                 ^Shutdown_Server_State,
		idle_sock:           net.TCP_Socket,
		idle_dial_err:       net.Network_Error,
		stalled_sock:        net.TCP_Socket,
		stalled_dial_err:    net.Network_Error,
		stalled_send_err:    net.TCP_Send_Error,
		handle_ok:           bool,
		ping:                Curl_Result,
		slow:                Curl_Result,
		shutdown_started_at: time.Time,
	}
	ctx := Shutdown_Ctx{srv = &srv_state}
	defer {
		curl_result_destroy(&ctx.ping)
		curl_result_destroy(&ctx.slow)
		if ctx.idle_sock != 0 { net.close(ctx.idle_sock) }
		if ctx.stalled_sock != 0 { net.close(ctx.stalled_sock) }
	}

	serve_finished_at, ok := run_test_server(
		t,
		{
			request_limits       = http.Limits{max_size = 64 * mem.Kilobyte, min = 200 * time.Millisecond, max = 250 * time.Millisecond},
			handlers             = {http.router(&r)},
			thread_initializer   = proc() {
				_tls_test_buf = make([]byte, 16)
				copy(_tls_test_buf, "tls-ok")
			},
			thread_deinitializer = proc() {
				delete(_tls_test_buf)
				_tls_test_buf = nil
			},
		},
		&ctx,
		proc(port: int, server: ^http.Server, ctx: ^Shutdown_Ctx) {
			endpoint := net.Endpoint{net.IP4_Loopback, port}

			ctx.idle_sock, ctx.idle_dial_err = net.dial_tcp(endpoint)
			if ctx.idle_dial_err != nil {
				http.server_shutdown(server)
				return
			}

			ctx.stalled_sock, ctx.stalled_dial_err = net.dial_tcp(endpoint)
			if ctx.stalled_dial_err != nil {
				http.server_shutdown(server)
				return
			}
			_, ctx.stalled_send_err = net.send_tcp(ctx.stalled_sock, transmute([]byte)string("GET /stalled"))
			if ctx.stalled_send_err != nil {
				http.server_shutdown(server)
				return
			}

			handle := curl.easy_init()
			ctx.handle_ok = handle != nil
			if handle == nil {
				http.server_shutdown(server)
				return
			}
			defer curl.easy_cleanup(handle)

			ctx.ping = curl_request(handle, port, "/ping")

			Shutdown_Thread_Ctx :: struct {
				server: ^http.Server,
				ctx:    ^Shutdown_Ctx,
			}
			st_ctx := Shutdown_Thread_Ctx{server = server, ctx = ctx}
			shutdown_thread := thread.create_and_start_with_data(&st_ctx, proc(raw: rawptr) {
				sc := (^Shutdown_Thread_Ctx)(raw)
				sync.one_shot_event_wait(&sc.ctx.srv.slow_started)
				sc.ctx.shutdown_started_at = time.now()
				http.server_shutdown(sc.server)
			})
			defer {
				sync.one_shot_event_signal(&ctx.srv.slow_started)
				thread.join(shutdown_thread)
				thread.destroy(shutdown_thread)
			}

			ctx.slow = curl_request(handle, port, "/slow")
		},
		auto_shutdown = false,
	)
	if !ok { return }
	if !testing.expect_value(t, ctx.idle_dial_err, nil) { return }
	if !testing.expect_value(t, ctx.stalled_dial_err, nil) { return }
	if !testing.expect_value(t, ctx.stalled_send_err, nil) { return }
	if !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	expect_curl_ok(t, "ping", ctx.ping, 200, "pong")
	expect_curl_ok(t, "slow", ctx.slow, 200, "slow-ok")
	slow_conn, has_slow_conn := curl_result_header(ctx.slow, "connection")
	testing.expect(t, has_slow_conn && strings.equal_fold(slow_conn, "close"), "expected in-flight response during shutdown to include Connection: close")

	shutdown_elapsed := time.diff(ctx.shutdown_started_at, serve_finished_at)
	testing.expect(t, shutdown_elapsed >= 100 * time.Millisecond, "expected shutdown to wait for request_limits on stalled active connection")
	testing.expect(t, shutdown_elapsed < 2 * time.Second, "expected shutdown not to hang past request_limits timeout")

	eof_buf: [16]byte
	idle_n, idle_recv_err := net.recv_tcp(ctx.idle_sock, eof_buf[:])
	testing.expect(t, idle_n == 0 || idle_recv_err != nil, "expected idle socket to be closed by server shutdown")

	_ = net.set_option(ctx.stalled_sock, .Receive_Timeout, 2 * time.Second)
	stalled_buf: [512]byte
	stalled_total := 0
	for stalled_total < len(stalled_buf) {
		n, err := net.recv_tcp(ctx.stalled_sock, stalled_buf[stalled_total:])
		if n <= 0 || err != nil { break }
		stalled_total += n
	}
	testing.expect(t, strings.has_prefix(string(stalled_buf[:stalled_total]), "HTTP/1.1 408 "), "expected stalled socket to receive 408 Request Timeout before closing")

	testing.expect(t, srv_state.handler_saw_tls, "expected handler to see thread_initializer state")
	testing.expect(t, _tls_test_buf == nil, "expected thread_deinitializer to clean up thread-local state")
}

@(test)
test_respond_file_content_type_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/readme", proc(ctx: ^http.Ctx) {
		http.respond_file_path(ctx, "core/http2/README.md")
	})
	http.route_get(&r, "/override", proc(ctx: ^http.Ctx) {
		http.set_header(ctx, "Content-Type", "application/custom")
		http.respond_file_path(ctx, "core/http2/README.md")
	})
	http.route_get(&r, "/license", proc(ctx: ^http.Ctx) {
		http.respond_file_path(ctx, "core/http/LICENSE")
	})
	http.route_get(&r, "/dir-only", proc(ctx: ^http.Ctx) {
		http.respond_file_path(ctx, "core/http2")
	})
	http.route_get(&r, "/content", proc(ctx: ^http.Ctx) {
		http.respond_file_content(ctx, "hello.json", transmute([]byte)string(`{"ok":true}`))
	})
	http.route_get(&r, "/static/*", proc(ctx: ^http.Ctx) {
		http.respond_dir(ctx, "core/http2", http.route_suffix(ctx))
	})
	http.route_get(&r, "/static", proc(ctx: ^http.Ctx) {
		http.respond_dir(ctx, "core/http2", http.route_suffix(ctx))
	})
	http.route_get(&r, "/old/*", proc(ctx: ^http.Ctx) {
		http.respond_dir(ctx, "core/http", http.route_suffix(ctx))
	})
	http.route_get(&r, "/old", proc(ctx: ^http.Ctx) {
		http.respond_dir(ctx, "core/http", http.route_suffix(ctx))
	})
	http.route_get(&r, "/file", proc(ctx: ^http.Ctx) {
		f, err := os.open("core/http2/README.md")
		if err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(ctx)
			return
		}
		http.response_defer(ctx, f, proc(_: ^http.Ctx, fp: ^os.File) {
			os.close(fp)
		})
		if assoc_err := http.respond_file(ctx, f); assoc_err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(ctx)
		}
	})

	Case_Spec :: struct {
		name:       string,
		path:       string,
		status:     int,
		has_ct:     bool,
		ct:         string,
		prefix:     string,
		location:   string,
	}
	specs := [?]Case_Spec{
		{"readme",            "/readme",                       200, true,  "text/markdown",      "# core/http2", ""},
		{"override",          "/override",                     200, true,  "application/custom", "# core/http2", ""},
		{"license",           "/license",                      200, false, "",                   "",             ""},
		{"via_file",          "/file",                         200, true,  "text/markdown",      "# core/http2", ""},
		{"content",           "/content",                      200, true,  "application/json",   `{"ok":true}`,  ""},
		{"dir_file",          "/static/README.md",             200, true,  "text/markdown",      "# core/http2", ""},
		{"dir_escape",        "/static/%2e%2e/http/LICENSE",   404, false, "",                   "",             ""},
		{"dir_index",         "/static/",                      404, false, "",                   "",             ""},
		{"dir_path",          "/dir-only",                     404, false, "",                   "",             ""},
		{"dir_root_redirect", "/static?v=1",                   307, false, "",                   "",             "/static/?v=1"},
		{"dir_sub_redirect",  "/old/dns",                      307, false, "",                   "",             "/old/dns/"},
		{"dir_encoded_slash", "/static/sub%2fREADME.md",       404, false, "",                   "",             ""},
	}

	Client_Ctx :: struct {
		specs:     []Case_Spec,
		results:   [12]Curl_Result,
		handle_ok: bool,
	}
	ctx := Client_Ctx{specs = specs[:]}
	defer for &res in ctx.results { curl_result_destroy(&res) }

	_, ok := run_test_server(t, {handlers = {http.router(&r)}}, &ctx, proc(port: int, _: ^http.Server, ctx: ^Client_Ctx) {
		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil { return }
		defer curl.easy_cleanup(handle)

		for spec, i in ctx.specs {
			ctx.results[i] = curl_request(handle, port, spec.path, {path_as_is = true})
		}
	})
	if !ok || !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	for spec, i in specs {
		res := ctx.results[i]
		expect_curl_ok(t, spec.name, res, spec.status)
		got_ct, has_ct := curl_result_header(res, "content-type")
		testing.expect_value(t, has_ct, spec.has_ct)
		if spec.has_ct {
			testing.expect_value(t, got_ct, spec.ct)
		}
		if spec.prefix != "" {
			testing.expectf(t, strings.has_prefix(curl_result_body(res), spec.prefix), "%s: unexpected body prefix", spec.name)
		}
		if spec.location != "" {
			loc_hdr, has_loc := curl_result_header(res, "location")
			testing.expect(t, has_loc)
			testing.expect_value(t, loc_hdr, spec.location)
		}
	}
	testing.expect(t, len(ctx.results[2].body) > 0, "expected non-empty LICENSE file body")
}

@(test)
test_respond_helpers_and_chunked_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	Json_Payload :: struct {
		msg:   string `json:"msg"`,
		count: int    `json:"count"`,
	}

	Chunk_Chain_State :: struct {
		step: int,
	}

	on_chunk_chain :: proc(ctx: ^http.Ctx, err: http.Send_Error) {
		if err != nil { return }
		st := http.context_get(ctx, Chunk_Chain_State)
		st.step += 1
		switch st.step {
		case 1:
			http.send_chunk(ctx, {nil, transmute([]byte)string("two-")})
			http.send_chunk(ctx, {transmute([]byte)string("three")}, on_chunk_chain)
		case 2:
			http.respond(ctx)
		}
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/plain", proc(ctx: ^http.Ctx) {
		http.respond_plain(ctx, "hello plain")
	})
	http.route_get(&r, "/html", proc(ctx: ^http.Ctx) {
		http.respond_html(ctx, "<h1>hello</h1>")
	})
	http.route_get(&r, "/json", proc(ctx: ^http.Ctx) {
		if err := http.respond_json(ctx, Json_Payload{msg = "ok", count = 3}); err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond_plain(ctx, "marshal error")
		}
	})
	http.route_get(&r, "/json-err", proc(ctx: ^http.Ctx) {
		bad := proc() {}
		if err := http.respond_json(ctx, bad); err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond_plain(ctx, "marshal error")
		}
	})
	http.route_get(&r, "/chunks", proc(ctx: ^http.Ctx) {
		http.context_add(ctx, Chunk_Chain_State{})
		http.send_chunk(ctx, {transmute([]byte)string("one-")}, on_chunk_chain)
	})

	Case_Spec :: struct {
		name:   string,
		path:   string,
		method: Curl_Method,
		status: int,
		has_ct: bool,
		ct:     string,
		body:   string,
	}
	specs := [?]Case_Spec{
		{"plain",           "/plain",    .Get,  200, true,  "text/plain",       "hello plain"},
		{"html",            "/html",     .Get,  200, true,  "text/html",        "<h1>hello</h1>"},
		{"json_get",        "/json",     .Get,  200, true,  "application/json", `{"msg":"ok","count":3}`},
		{"json_head",       "/json",     .Head, 200, true,  "application/json", ""},
		{"json_err",        "/json-err", .Get,  500, true,  "text/plain",       "marshal error"},
		{"chunks",          "/chunks",   .Get,  200, false, "",                 "one-two-three"},
		{"chunks_head",     "/chunks",   .Head, 200, false, "",                 ""},
		{"after_keepalive", "/plain",    .Get,  200, true,  "text/plain",       "hello plain"},
	}

	Client_Ctx :: struct {
		specs:     []Case_Spec,
		results:   [8]Curl_Result,
		handle_ok: bool,
	}
	ctx := Client_Ctx{specs = specs[:]}
	defer for &res in ctx.results { curl_result_destroy(&res) }

	_, ok := run_test_server(t, {handlers = {http.router(&r)}}, &ctx, proc(port: int, _: ^http.Server, ctx: ^Client_Ctx) {
		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil { return }
		defer curl.easy_cleanup(handle)

		for spec, i in ctx.specs {
			ctx.results[i] = curl_request(handle, port, spec.path, {method = spec.method})
		}
	})
	if !ok || !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	for spec, i in specs {
		res := ctx.results[i]
		expect_curl_ok(t, spec.name, res, spec.status, spec.body)
		got_ct, has_ct := curl_result_header(res, "content-type")
		testing.expect_value(t, has_ct, spec.has_ct)
		if spec.has_ct {
			testing.expect_value(t, got_ct, spec.ct)
		}
	}
}

@(test)
test_temp_allocator_binding_and_tick_reset :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	Counting_Temp_Allocator :: struct {
		backing:        mem.Allocator,
		free_all_count: int,
	}
	counting := Counting_Temp_Allocator{backing = context.temp_allocator}
	counting_proc :: proc(
		allocator_data: rawptr,
		mode: mem.Allocator_Mode,
		size, alignment: int,
		old_memory: rawptr,
		old_size: int,
		location := #caller_location,
	) -> ([]byte, mem.Allocator_Error) {
		ct := (^Counting_Temp_Allocator)(allocator_data)
		if mode == .Free_All {
			ct.free_all_count += 1
		}
		return ct.backing.procedure(ct.backing.data, mode, size, alignment, old_memory, old_size, location)
	}

	prev_temp := context.temp_allocator
	context.temp_allocator = mem.Allocator{procedure = counting_proc, data = &counting}
	defer context.temp_allocator = prev_temp

	Temp_Check_State :: struct {
		defer_calls:    int,
		defer_matched:  int,
		handler_socket: nbio.TCP_Socket,
		defer_socket:   nbio.TCP_Socket,
	}
	srv_state: Temp_Check_State

	r: http.Router
	defer http.router_destroy(r)

	register_defer_check :: proc(ctx: ^http.Ctx, st: ^Temp_Check_State, capture_socket := false) {
		if capture_socket {
			st.handler_socket = http._connection_of_context(ctx).socket
		}
		http.context_add(ctx, st)
		http.response_defer(ctx, capture_socket, proc(ctx: ^http.Ctx, capture_socket: bool) {
			st := http.context_get(ctx, ^Temp_Check_State)^
			st.defer_calls += 1
			if context.temp_allocator.data == http.temp_allocator(ctx).data {
				st.defer_matched += 1
			}
			if capture_socket {
				st.defer_socket = http._connection_of_context(ctx).socket
			}
			scratch, serr := make([]byte, 64, context.temp_allocator)
			if serr == nil && len(scratch) == 64 {
				scratch[0] = 1
			}
		})
	}

	http.route_get(&r, "/ok", http.handler(&srv_state, proc(user_data: rawptr, ctx: ^http.Ctx) {
		register_defer_check(ctx, (^Temp_Check_State)(user_data))
		http.respond_bytes(ctx, transmute([]byte)string("ok"))
	}))
	http.route_get(&r, "/file", http.handler(&srv_state, proc(user_data: rawptr, ctx: ^http.Ctx) {
		register_defer_check(ctx, (^Temp_Check_State)(user_data))
		http.respond_file_path(ctx, "core/http2/README.md")
	}))
	http.route_get(&r, "/missing", http.handler(&srv_state, proc(user_data: rawptr, ctx: ^http.Ctx) {
		register_defer_check(ctx, (^Temp_Check_State)(user_data))
		http.respond_file_path(ctx, "core/http2/__does_not_exist__")
	}))
	http.route_get(&r, "/close", http.handler(&srv_state, proc(user_data: rawptr, ctx: ^http.Ctx) {
		register_defer_check(ctx, (^Temp_Check_State)(user_data), capture_socket = true)
		http.set_header(ctx, "connection", "close")
		http.respond_bytes(ctx, transmute([]byte)string("bye"))
	}))

	Client_Ctx :: struct {
		handle_ok: bool,
		results:   [4]Curl_Result,
	}
	client_ctx: Client_Ctx
	defer for &res in client_ctx.results { curl_result_destroy(&res) }

	_, ok := run_test_server(t, {handlers = {http.router(&r)}}, &client_ctx, proc(port: int, _: ^http.Server, ctx: ^Client_Ctx) {
		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil { return }
		defer curl.easy_cleanup(handle)

		for p, i in ([4]string{"/ok", "/file", "/missing", "/close"}) {
			ctx.results[i] = curl_request(handle, port, p)
		}
	})
	if !ok || !testing.expect(t, client_ctx.handle_ok, "expected curl handle") { return }

	expected_statuses := [4]int{200, 200, 404, 200}
	for want_status, i in expected_statuses {
		expect_curl_ok(t, "temp_check", client_ctx.results[i], want_status)
	}
	testing.expect_value(t, srv_state.defer_calls, 4)
	testing.expect_value(t, srv_state.defer_matched, 4)
	testing.expect(t, srv_state.handler_socket != {}, "expected non-zero socket in handler")
	testing.expect_value(t, srv_state.defer_socket, srv_state.handler_socket)
	testing.expect(t, counting.free_all_count > 0, "expected _server_thread_serve to free_all context.temp_allocator across ticks")
}

@(test)
test_range_requests_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	CONTENT :: "0123456789"

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/file", proc(ctx: ^http.Ctx) {
		http.respond_file_path(ctx, "core/http2/README.md")
	})
	http.route_get(&r, "/content", proc(ctx: ^http.Ctx) {
		http.set_header(ctx, "ETag", `"v1"`)
		http.respond_file_content(ctx, "data.txt", transmute([]byte)string(CONTENT))
	})
	http.route_post(&r, "/content", proc(ctx: ^http.Ctx) {
		http.set_header(ctx, "ETag", `"v1"`)
		http.respond_file_content(ctx, "data.txt", transmute([]byte)string(CONTENT))
	})
	http.route_get(&r, "/weak", proc(ctx: ^http.Ctx) {
		http.set_header(ctx, "ETag", `W/"v1"`)
		http.respond_file_content(ctx, "data.txt", transmute([]byte)string(CONTENT))
	})
	http.route_get(&r, "/no-range", proc(ctx: ^http.Ctx) {
		http.set_header(ctx, "Accept-Ranges", "none")
		http.respond_file_content(ctx, "data.txt", transmute([]byte)string(CONTENT))
	})

	readme_bytes, readme_err := os.read_entire_file("core/http2/README.md", context.allocator)
	testing.expect_value(t, readme_err, nil)
	defer delete(readme_bytes)
	exp_file_cr := fmt.aprintf("bytes 0-15/%d", len(readme_bytes))
	defer delete(exp_file_cr)

	Range_Spec :: struct {
		name:     string,
		path:     string,
		method:   Curl_Method,
		range_h:  string,
		if_range: string, // "$LM" substitutes Last-Modified from case 0
		status:   int,
		ar:       string,
		cr:       string,
		body:     string,
	}

	specs := [?]Range_Spec{
		{"file_range",       "/file",     .Get,  "bytes=0-15",     "",                               206, "bytes", exp_file_cr,    string(readme_bytes[:16])},
		{"file_if_match",    "/file",     .Get,  "bytes=0-15",     "$LM",                            206, "bytes", exp_file_cr,    string(readme_bytes[:16])},
		{"file_if_older",    "/file",     .Get,  "bytes=0-15",     "Fri, 05 Feb 2023 09:01:10 GMT",  200, "bytes", "",             string(readme_bytes)},
		{"file_if_future",   "/file",     .Get,  "bytes=0-15",     "Thu, 01 Jan 2099 00:00:00 GMT",  200, "bytes", "",             string(readme_bytes)},
		{"content_range",    "/content",  .Get,  "bytes=2-5",      "",                               206, "bytes", "bytes 2-5/10", "2345"},
		{"content_head",     "/content",  .Head, "bytes=2-5",      "",                               206, "bytes", "bytes 2-5/10", ""},
		{"content_suffix",   "/content",  .Get,  "bytes=-3",       "",                               206, "bytes", "bytes 7-9/10", "789"},
		{"content_neg_zero", "/content",  .Get,  "bytes=-0",       "",                               416, "bytes", "bytes */10",   ""},
		{"content_oob",      "/content",  .Get,  "bytes=20-30",    "",                               416, "bytes", "bytes */10",   ""},
		{"content_multi",    "/content",  .Get,  "bytes=0-1, 4-5", "",                               200, "bytes", "",             CONTENT},
		{"etag_match",       "/content",  .Get,  "bytes=2-5",      `"v1"`,                           206, "bytes", "bytes 2-5/10", "2345"},
		{"etag_mismatch",    "/content",  .Get,  "bytes=2-5",      `"v2"`,                           200, "bytes", "",             CONTENT},
		{"etag_weak_req",    "/content",  .Get,  "bytes=2-5",      `W/"v1"`,                         200, "bytes", "",             CONTENT},
		{"etag_weak_res",    "/weak",     .Get,  "bytes=2-5",      `"v1"`,                           200, "bytes", "",             CONTENT},
		{"no_range",         "/no-range", .Get,  "bytes=2-5",      "",                               200, "none",  "",             CONTENT},
		{"post_range",       "/content",  .Post, "bytes=2-5",      "",                               200, "bytes", "",             CONTENT},
	}

	Client_Ctx :: struct {
		specs:     []Range_Spec,
		results:   [16]Curl_Result,
		handle_ok: bool,
	}
	ctx := Client_Ctx{specs = specs[:]}
	defer for &res in ctx.results { curl_result_destroy(&res) }

	_, ok := run_test_server(t, {handlers = {http.router(&r)}}, &ctx, proc(port: int, _: ^http.Server, ctx: ^Client_Ctx) {
		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil { return }
		defer curl.easy_cleanup(handle)

		lm := ""
		for spec, i in ctx.specs {
			if_range := lm if spec.if_range == "$LM" else spec.if_range
			hdrs_buf: [2]string
			hdr_count := 1
			hdrs_buf[0] = fmt.tprintf("Range: %s", spec.range_h)
			if if_range != "" {
				hdrs_buf[1] = fmt.tprintf("If-Range: %s", if_range)
				hdr_count = 2
			}
			ctx.results[i] = curl_request(handle, port, spec.path, {
				method  = spec.method,
				headers = hdrs_buf[:hdr_count],
			})
			if i == 0 {
				lm, _ = curl_result_header(ctx.results[0], "last-modified")
			}
		}
	})
	if !ok || !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	lm_val, lm_ok := curl_result_header(ctx.results[0], "last-modified")
	testing.expect(t, lm_ok && len(lm_val) > 0, "expected Last-Modified header")

	for spec, i in specs {
		res := ctx.results[i]
		expect_curl_ok(t, spec.name, res, spec.status, spec.body)
		if spec.ar != "" {
			ar, _ := curl_result_header(res, "accept-ranges")
			testing.expect_value(t, ar, spec.ar)
		}
		if spec.cr != "" {
			cr, _ := curl_result_header(res, "content-range")
			testing.expect_value(t, cr, spec.cr)
		}
	}
	head_cl, _ := curl_result_header(ctx.results[5], "content-length")
	testing.expect_value(t, head_cl, "4")
}

@(test)
test_server_shutdown_async :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = http.OS_ASSIGNED_PORT,
		thread_count = 2,
		handlers     = {proc(ctx: ^http.Ctx) {
			http.set_header(ctx, "Connection", "close")
			http.respond_plain(ctx, "ok")
		}},
	})

	// Before _serve starts, server_shutdown_async returns false.
	testing.expect(t, !http.server_shutdown_async(&server), "expected false before _serve")

	Client_Ctx :: struct {
		handle_ok:    bool,
		first_async:  bool,
		second_async: bool,
		res:          Curl_Result,
	}
	ctx: Client_Ctx
	defer curl_result_destroy(&ctx.res)

	_, ok := run_test_server_existing(
		t,
		&server,
		&ctx,
		proc(port: int, server: ^http.Server, ctx: ^Client_Ctx) {
			defer {
				ctx.first_async  = http.server_shutdown_async(server)
				ctx.second_async = http.server_shutdown_async(server)
				if !ctx.first_async {
					http.server_shutdown(server)
				}
			}

			handle := curl.easy_init()
			ctx.handle_ok = handle != nil
			if handle == nil { return }
			defer curl.easy_cleanup(handle)

			ctx.res = curl_request(handle, port, "/")
		},
		auto_shutdown = false,
	)
	if !ok || !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	expect_curl_ok(t, "shutdown_async", ctx.res, 200, "ok")
	testing.expect(t, ctx.first_async, "expected first server_shutdown_async to return true")
	testing.expect(t, !ctx.second_async, "expected second server_shutdown_async to return false")
	testing.expect(t, !http.server_shutdown_async(&server), "expected false after _serve completes")
}

@(test)
test_middleware_pipeline_and_subrouter_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	Auth_Tag :: struct {
		user: string,
	}

	outer_mw := proc(ctx: ^http.Ctx, next: []http.Handler) {
		http.set_header(ctx, "X-Outer", "1")
		http.handle(next, ctx)
	}

	require_user := proc(ctx: ^http.Ctx, next: []http.Handler) {
		u, ok := http.get_header(ctx, "X-User")
		if !ok || u == "" {
			ctx.res.status = .Unauthorized
			http.respond_plain(ctx, "unauthorized")
			return
		}
		http.context_add(ctx, Auth_Tag{user = u})
		http.set_header(ctx, "X-Authed", u)
		http.handle(next, ctx)
	}

	api: http.Router
	defer http.router_destroy(api)
	http.route_post(&api, "/echo", http.body_parser, proc(ctx: ^http.Ctx) {
		body, ok := http.body_parser_collect(ctx)
		if !ok {
			ctx.res.status = .Bad_Request
			http.respond(ctx)
			return
		}
		tag := http.context_get(ctx, Auth_Tag)
		http.respond_plain(ctx, fmt.aprintf("%s:%s", tag.user, string(body), allocator = http.transaction_allocator(ctx)))
	})

	root: http.Router
	defer http.router_destroy(root)
	http.route_all(&root, "/api/*", require_user, http.router(&api))

	Client_Ctx :: struct {
		handle_ok: bool,
		unauth:    Curl_Result,
		authed:    Curl_Result,
		not_found: Curl_Result,
	}
	ctx: Client_Ctx
	defer {
		curl_result_destroy(&ctx.unauth)
		curl_result_destroy(&ctx.authed)
		curl_result_destroy(&ctx.not_found)
	}

	_, ok := run_test_server(
		t,
		{handlers = {outer_mw, http.router(&root)}},
		&ctx,
		proc(port: int, _: ^http.Server, ctx: ^Client_Ctx) {
			handle := curl.easy_init()
			ctx.handle_ok = handle != nil
			if handle == nil { return }
			defer curl.easy_cleanup(handle)

			payload := transmute([]byte)string("hello")
			ctx.unauth    = curl_request(handle, port, "/api/echo", {.Post, nil, payload, false})
			ctx.authed    = curl_request(handle, port, "/api/echo", {.Post, {"X-User: alice"}, payload, false})
			ctx.not_found = curl_request(handle, port, "/missing")
		},
	)
	if !ok || !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	expect_curl_ok(t, "unauth", ctx.unauth, 401, "unauthorized")
	outer_1, _ := curl_result_header(ctx.unauth, "x-outer")
	testing.expect_value(t, outer_1, "1")

	expect_curl_ok(t, "authed", ctx.authed, 200, "alice:hello")
	outer_2, _ := curl_result_header(ctx.authed, "x-outer")
	authed_h, _ := curl_result_header(ctx.authed, "x-authed")
	testing.expect_value(t, outer_2, "1")
	testing.expect_value(t, authed_h, "alice")

	expect_curl_ok(t, "not_found", ctx.not_found, 404)
}
