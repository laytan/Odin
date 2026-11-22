#+build windows, linux, darwin
package tests_http2

import "base:runtime"
import "base:sanitizer"

import c "core:c/libc"
import "core:container/xar"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:net"
import "core:nbio"
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

Functional_Server :: struct {
	server: http.Server,
}

Curl_Response :: struct {
	body:   [dynamic]byte,
	status: c.long,
}

Curl_Test_Context :: struct {
	state:                ^Functional_Server,
	endpoint_err:         net.Socket_Info_Error,
	handle_ok:            bool,
	setopt_url_err:       curl.code,
	setopt_writefn_err:   curl.code,
	setopt_writedata_err: curl.code,
	perform_err:          curl.code,
	getinfo_err:          curl.code,
	response:             Curl_Response,
}

http2_test_handler :: proc(ctx: ^http.Ctx) {
	if ctx.req.line.target != "/ping" {
		ctx.res.status = .Not_Found
		http.respond(&ctx.res)
		return
	}

	body := "pong"
	http.set_header(&ctx.res, "connection", "close")
	http.set_content_length_header(&ctx.res, len(body))
	http.send(&ctx.res, {transmute([]byte)body})
	http.respond(&ctx.res)
}

curl_write_response :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
	context = runtime.default_context()

	response := (^Curl_Response)(userp)
	real_size := int(size) * int(nmemb)
	old_len := len(response.body)
	resize(&response.body, old_len+real_size)
	copy(response.body[old_len:], contents[:real_size])

	return c.size_t(real_size)
}

@(test)
test_http2_server_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	state: Functional_Server
	state.server = http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18080,
		thread_count = 1,
		handler      = http.handler(http2_test_handler),
	})

	setup_err := http._setup(&state.server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&state.server)
		return
	}

	curl_ctx := Curl_Test_Context{state = &state}
	defer delete(curl_ctx.response.body)

	client_thread := thread.create_and_start_with_data(&curl_ctx, proc(data: rawptr) {
		ctx := (^Curl_Test_Context)(data)
		s := ctx.state
		defer http.server_shutdown(&s.server)

		endpoint, endpoint_err := nbio.bound_endpoint(s.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil {
			return
		}

		url := fmt.ctprintf("http://127.0.0.1:%d/ping", endpoint.port)

		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil {
			return
		}
		defer curl.easy_cleanup(handle)

		ctx.setopt_url_err       = curl.easy_setopt(handle, .URL, url)
		ctx.setopt_writefn_err   = curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_response)
		ctx.setopt_writedata_err = curl.easy_setopt(handle, .WRITEDATA, &ctx.response)

		ctx.perform_err = curl.easy_perform(handle)
		ctx.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &ctx.response.status)
	})

	http._serve(&state.server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&state.server)

	if !testing.expect_value(t, curl_ctx.endpoint_err, nil) {
		return
	}
	if !testing.expect(t, curl_ctx.handle_ok, "curl.easy_init failed") {
		return
	}
	testing.expect_value(t, curl_ctx.setopt_url_err, curl.code.E_OK)
	testing.expect_value(t, curl_ctx.setopt_writefn_err, curl.code.E_OK)
	testing.expect_value(t, curl_ctx.setopt_writedata_err, curl.code.E_OK)
	testing.expectf(t, curl_ctx.perform_err == curl.code.E_OK, "curl request failed: %s", curl.easy_strerror(curl_ctx.perform_err))
	testing.expect_value(t, curl_ctx.getinfo_err, curl.code.E_OK)
	testing.expect_value(t, curl_ctx.response.status, c.long(200))
	testing.expect_value(t, string(curl_ctx.response.body[:]), "pong")
}

Expect_Case_Result :: struct {
	handle_ok:   bool,
	setopt_ok:   bool,
	perform_err: curl.code,
	getinfo_err: curl.code,
	saw_100:     bool,
	response:    Curl_Response,
}

Expect_Test_Context :: struct {
	server:       ^http.Server,
	endpoint_err: net.Socket_Info_Error,
	echo_ok:      Expect_Case_Result,
	reject_401:   Expect_Case_Result,
	too_big_413:  Expect_Case_Result,
}

curl_check_100_header :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
	context = runtime.default_context()

	real_size := int(size) * int(nmemb)
	line := string(contents[:real_size])
	if strings.has_prefix(line, "HTTP/1.1 100 Continue") {
		saw_100 := (^bool)(userp)
		saw_100^ = true
	}

	return c.size_t(real_size)
}

@(test)
test_http2_lazy_expect_continue_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	Echo_Buf :: struct {
		data: [dynamic]byte,
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_post(&r, "/echo", proc(ctx: ^http.Ctx) {
		eb := http.context_add(ctx, Echo_Buf{
			data = make([dynamic]byte, http.transaction_allocator(ctx)),
		})
		http.body(&ctx.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {
			ctx := http.context_of_request(req)
			eb := http.context_get(ctx, Echo_Buf)
			if len(body) > 0 {
				append(&eb.data, ..body)
			}
			if !is_partial {
				http.respond_bytes(&ctx.res, eb.data[:])
			}
		})
	})
	http.route_post(&r, "/reject", proc(ctx: ^http.Ctx) {
		ctx.res.status = .Unauthorized
		http.respond(&ctx.res)
	})

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18082,
		thread_count = 1,
		body_quota   = {max_size = 4096, min = 5 * time.Second},
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	ctx := Expect_Test_Context{server = &server}
	defer delete(ctx.echo_ok.response.body)
	defer delete(ctx.reject_401.response.body)
	defer delete(ctx.too_big_413.response.body)

	client_thread := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		ctx := (^Expect_Test_Context)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil {
			return
		}

		do_post :: proc(port: int, path: string, body: []byte, res: ^Expect_Case_Result) {
			handle := curl.easy_init()
			res.handle_ok = handle != nil
			if handle == nil {
				return
			}
			defer curl.easy_cleanup(handle)

			hdrs := curl.slist_append(nil, "Expect: 100-continue")
			defer curl.slist_free_all(hdrs)

			url := fmt.ctprintf("http://127.0.0.1:%d%s", port, path)
			res.setopt_ok = hdrs != nil &&
				curl.easy_setopt(handle, .URL, url) == .E_OK &&
				curl.easy_setopt(handle, .HTTPHEADER, hdrs) == .E_OK &&
				curl.easy_setopt(handle, .POSTFIELDS, raw_data(body)) == .E_OK &&
				curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(len(body))) == .E_OK &&
				curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_response) == .E_OK &&
				curl.easy_setopt(handle, .WRITEDATA, &res.response) == .E_OK &&
				curl.easy_setopt(handle, .HEADERFUNCTION, curl_check_100_header) == .E_OK &&
				curl.easy_setopt(handle, .HEADERDATA, &res.saw_100) == .E_OK
			if !res.setopt_ok {
				return
			}

			res.perform_err = curl.easy_perform(handle)
			res.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.response.status)
		}

		small_payload: [2048]byte
		for &b in small_payload { b = 'a' }
		large_payload: [8192]byte
		for &b in large_payload { b = 'b' }

		do_post(endpoint.port, "/echo", small_payload[:], &ctx.echo_ok)
		do_post(endpoint.port, "/reject", small_payload[:], &ctx.reject_401)
		do_post(endpoint.port, "/echo", large_payload[:], &ctx.too_big_413)
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, ctx.endpoint_err, nil) {
		return
	}

	expected_small: [2048]byte
	for &b in expected_small { b = 'a' }

	// 1. Accepted POST calling body() receives 100 Continue and echoes full payload.
	testing.expect(t, ctx.echo_ok.handle_ok, "echo_ok: curl.easy_init failed")
	testing.expect(t, ctx.echo_ok.setopt_ok, "echo_ok: curl.easy_setopt failed")
	testing.expectf(t, ctx.echo_ok.perform_err == .E_OK, "echo_ok: curl failed: %s", curl.easy_strerror(ctx.echo_ok.perform_err))
	testing.expect_value(t, ctx.echo_ok.getinfo_err, curl.code.E_OK)
	testing.expect(t, ctx.echo_ok.saw_100, "expected POST /echo to receive HTTP/1.1 100 Continue")
	testing.expect_value(t, ctx.echo_ok.response.status, c.long(200))
	testing.expect_value(t, string(ctx.echo_ok.response.body[:]), string(expected_small[:]))

	// 2. Rejected POST (401) that never calls body() does NOT receive 100 Continue.
	testing.expect(t, ctx.reject_401.handle_ok, "reject_401: curl.easy_init failed")
	testing.expect(t, ctx.reject_401.setopt_ok, "reject_401: curl.easy_setopt failed")
	testing.expectf(t, ctx.reject_401.perform_err == .E_OK, "reject_401: curl failed: %s", curl.easy_strerror(ctx.reject_401.perform_err))
	testing.expect_value(t, ctx.reject_401.getinfo_err, curl.code.E_OK)
	testing.expect(t, !ctx.reject_401.saw_100, "expected rejected POST /reject not to receive 100 Continue")
	testing.expect_value(t, ctx.reject_401.response.status, c.long(401))

	// 3. Oversized POST (413) rejected by body_quota does NOT receive 100 Continue.
	testing.expect(t, ctx.too_big_413.handle_ok, "too_big_413: curl.easy_init failed")
	testing.expect(t, ctx.too_big_413.setopt_ok, "too_big_413: curl.easy_setopt failed")
	testing.expectf(t, ctx.too_big_413.perform_err == .E_OK, "too_big_413: curl failed: %s", curl.easy_strerror(ctx.too_big_413.perform_err))
	testing.expect_value(t, ctx.too_big_413.getinfo_err, curl.code.E_OK)
	testing.expect(t, !ctx.too_big_413.saw_100, "expected 413 POST /echo not to receive 100 Continue")
	testing.expect_value(t, ctx.too_big_413.response.status, c.long(413))
}

Head_Case_Result :: struct {
	setopt_ok:      bool,
	perform_err:    curl.code,
	getinfo_err:    curl.code,
	clen_err:       curl.code,
	content_length: curl.off_t,
	response:       Curl_Response,
}

Head_Server_State :: struct {
	ping_count:         int,
	ping_methods:       [2]http.Method,
	custom_head_count:  int,
	custom_head_method: http.Method,
	custom_get_count:   int,
	custom_get_method:  http.Method,
}

Head_Test_Context :: struct {
	server:       ^http.Server,
	endpoint_err: net.Socket_Info_Error,
	handle_ok:    bool,
	head_ping:    Head_Case_Result,
	get_ping:     Head_Case_Result,
	head_custom:  Head_Case_Result,
	get_custom:   Head_Case_Result,
}

@(test)
test_http2_head_requests_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	srv_state: Head_Server_State

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ping", http.Handler{
		user_data = &srv_state,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			st := (^Head_Server_State)(h.user_data)
			if st.ping_count < len(st.ping_methods) {
				st.ping_methods[st.ping_count] = ctx.req.line.method
			}
			st.ping_count += 1
			http.respond_bytes(&ctx.res, transmute([]byte)string("pong"))
		},
	})
	http.route_head(&r, "/custom", http.Handler{
		user_data = &srv_state,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			st := (^Head_Server_State)(h.user_data)
			st.custom_head_count += 1
			st.custom_head_method = ctx.req.line.method
			http.set_content_length_header(&ctx.res, 9)
			http.respond(&ctx.res)
		},
	})
	http.route_get(&r, "/custom", http.Handler{
		user_data = &srv_state,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			st := (^Head_Server_State)(h.user_data)
			st.custom_get_count += 1
			st.custom_get_method = ctx.req.line.method
			http.respond_bytes(&ctx.res, transmute([]byte)string("custom-ok"))
		},
	})

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18083,
		thread_count = 1,
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	ctx := Head_Test_Context{server = &server}
	defer delete(ctx.head_ping.response.body)
	defer delete(ctx.get_ping.response.body)
	defer delete(ctx.head_custom.response.body)
	defer delete(ctx.get_custom.response.body)

	client_thread := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		ctx := (^Head_Test_Context)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil {
			return
		}

		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil {
			return
		}
		defer curl.easy_cleanup(handle)

		do_req :: proc(handle: ^curl.CURL, port: int, path: string, is_head: bool, res: ^Head_Case_Result) {
			url := fmt.ctprintf("http://127.0.0.1:%d%s", port, path)
			method_ok := curl.easy_setopt(handle, .NOBODY, c.long(1)) == .E_OK if is_head else (
				curl.easy_setopt(handle, .NOBODY, c.long(0)) == .E_OK &&
				curl.easy_setopt(handle, .HTTPGET, c.long(1)) == .E_OK
			)
			res.setopt_ok = method_ok &&
				curl.easy_setopt(handle, .URL, url) == .E_OK &&
				curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_response) == .E_OK &&
				curl.easy_setopt(handle, .WRITEDATA, &res.response) == .E_OK
			if !res.setopt_ok {
				return
			}

			res.perform_err = curl.easy_perform(handle)
			res.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.response.status)
			res.clen_err    = curl.easy_getinfo(handle, .CONTENT_LENGTH_DOWNLOAD_T, &res.content_length)
		}

		do_req(handle, endpoint.port, "/ping", true, &ctx.head_ping)
		do_req(handle, endpoint.port, "/ping", false, &ctx.get_ping)
		do_req(handle, endpoint.port, "/custom", true, &ctx.head_custom)
		do_req(handle, endpoint.port, "/custom", false, &ctx.get_custom)
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, ctx.endpoint_err, nil) {
		return
	}
	if !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") {
		return
	}

	// 1. HEAD /ping falls back to route_get, receives Content-Length: 4 and empty body, and handler sees .Head.
	testing.expect(t, ctx.head_ping.setopt_ok, "head_ping: setopt failed")
	testing.expectf(t, ctx.head_ping.perform_err == .E_OK, "head_ping: curl failed: %s", curl.easy_strerror(ctx.head_ping.perform_err))
	testing.expect_value(t, ctx.head_ping.getinfo_err, curl.code.E_OK)
	testing.expect_value(t, ctx.head_ping.clen_err, curl.code.E_OK)
	testing.expect_value(t, ctx.head_ping.response.status, c.long(200))
	testing.expect_value(t, ctx.head_ping.content_length, curl.off_t(4))
	testing.expect_value(t, len(ctx.head_ping.response.body), 0)

	// 2. Subsequent GET /ping on the same keep-alive connection receives full "pong" body and handler sees .Get.
	testing.expect(t, ctx.get_ping.setopt_ok, "get_ping: setopt failed")
	testing.expectf(t, ctx.get_ping.perform_err == .E_OK, "get_ping: curl failed: %s", curl.easy_strerror(ctx.get_ping.perform_err))
	testing.expect_value(t, ctx.get_ping.getinfo_err, curl.code.E_OK)
	testing.expect_value(t, ctx.get_ping.response.status, c.long(200))
	testing.expect_value(t, string(ctx.get_ping.response.body[:]), "pong")

	// 3. HEAD /custom hits explicit route_head (Content-Length: 9, empty body).
	testing.expect(t, ctx.head_custom.setopt_ok, "head_custom: setopt failed")
	testing.expectf(t, ctx.head_custom.perform_err == .E_OK, "head_custom: curl failed: %s", curl.easy_strerror(ctx.head_custom.perform_err))
	testing.expect_value(t, ctx.head_custom.getinfo_err, curl.code.E_OK)
	testing.expect_value(t, ctx.head_custom.clen_err, curl.code.E_OK)
	testing.expect_value(t, ctx.head_custom.response.status, c.long(200))
	testing.expect_value(t, ctx.head_custom.content_length, curl.off_t(9))
	testing.expect_value(t, len(ctx.head_custom.response.body), 0)

	// 4. GET /custom hits route_get ("custom-ok").
	testing.expect(t, ctx.get_custom.setopt_ok, "get_custom: setopt failed")
	testing.expectf(t, ctx.get_custom.perform_err == .E_OK, "get_custom: curl failed: %s", curl.easy_strerror(ctx.get_custom.perform_err))
	testing.expect_value(t, ctx.get_custom.getinfo_err, curl.code.E_OK)
	testing.expect_value(t, ctx.get_custom.response.status, c.long(200))
	testing.expect_value(t, string(ctx.get_custom.response.body[:]), "custom-ok")

	// Server-side handler observations.
	testing.expect_value(t, srv_state.ping_count, 2)
	testing.expect_value(t, srv_state.ping_methods[0], http.Method.Head)
	testing.expect_value(t, srv_state.ping_methods[1], http.Method.Get)
	testing.expect_value(t, srv_state.custom_head_count, 1)
	testing.expect_value(t, srv_state.custom_head_method, http.Method.Head)
	testing.expect_value(t, srv_state.custom_get_count, 1)
	testing.expect_value(t, srv_state.custom_get_method, http.Method.Get)
}

@(thread_local, private="file")
_tls_test_buf: []byte

Shutdown_Server_State :: struct {
	slow_started:    sync.One_Shot_Event,
	handler_saw_tls: bool,
}

Shutdown_Test_Context :: struct {
	server:              ^http.Server,
	srv:                 ^Shutdown_Server_State,
	endpoint_err:        net.Socket_Info_Error,
	idle_sock:           net.TCP_Socket,
	idle_dial_err:       net.Network_Error,
	stalled_sock:        net.TCP_Socket,
	stalled_dial_err:    net.Network_Error,
	stalled_send_err:    net.TCP_Send_Error,
	handle_ok:           bool,
	ping_setopt_ok:      bool,
	ping_perform_err:    curl.code,
	ping_getinfo_err:    curl.code,
	ping_res:            Curl_Response,
	slow_setopt_ok:      bool,
	slow_perform_err:    curl.code,
	slow_getinfo_err:    curl.code,
	slow_saw_conn_close: bool,
	slow_res:            Curl_Response,
	shutdown_started_at: time.Time,
}

curl_check_conn_close_header :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
	context = runtime.default_context()

	real_size := int(size) * int(nmemb)
	line := strings.trim_space(string(contents[:real_size]))
	if strings.equal_fold(line, "connection: close") {
		saw_close := (^bool)(userp)
		saw_close^ = true
	}

	return c.size_t(real_size)
}

@(test)
test_http2_graceful_shutdown_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	srv_state: Shutdown_Server_State

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ping", proc(ctx: ^http.Ctx) {
		http.respond_bytes(&ctx.res, transmute([]byte)string("pong"))
	})
	http.route_get(&r, "/slow", http.Handler{
		user_data = &srv_state,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			st := (^Shutdown_Server_State)(h.user_data)
			st.handler_saw_tls = len(_tls_test_buf) >= 6 && string(_tls_test_buf[:6]) == "tls-ok"
			sync.one_shot_event_signal(&st.slow_started)
			nbio.timeout_poly(40 * time.Millisecond, ctx, proc(_: ^nbio.Operation, ctx: ^http.Ctx) {
				http.respond_bytes(&ctx.res, transmute([]byte)string("slow-ok"))
			})
		},
	})

	server := http.make_server(http.Server_Options{
		address              = nbio.IP4_Loopback,
		port                 = 18084,
		thread_count         = 1,
		request_quota        = http.Quota{max_size = 64 * mem.Kilobyte, min = 200 * time.Millisecond, max = 250 * time.Millisecond},
		handler              = http.router(&r),
		thread_initializer = proc() {
			_tls_test_buf = make([]byte, 16)
			copy(_tls_test_buf, "tls-ok")
		},
		thread_deinitializer = proc() {
			delete(_tls_test_buf)
			_tls_test_buf = nil
		},
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	ctx := Shutdown_Test_Context{
		server = &server,
		srv    = &srv_state,
	}
	defer delete(ctx.ping_res.body)
	defer delete(ctx.slow_res.body)
	defer if ctx.idle_sock != 0 { net.close(ctx.idle_sock) }
	defer if ctx.stalled_sock != 0 { net.close(ctx.stalled_sock) }

	client_thread := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		ctx := (^Shutdown_Test_Context)(data)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil {
			http.server_shutdown(ctx.server)
			return
		}

		ctx.idle_sock, ctx.idle_dial_err = net.dial_tcp(endpoint)
		if ctx.idle_dial_err != nil {
			http.server_shutdown(ctx.server)
			return
		}

		ctx.stalled_sock, ctx.stalled_dial_err = net.dial_tcp(endpoint)
		if ctx.stalled_dial_err != nil {
			http.server_shutdown(ctx.server)
			return
		}
		_, ctx.stalled_send_err = net.send_tcp(ctx.stalled_sock, transmute([]byte)string("GET /stalled"))
		if ctx.stalled_send_err != nil {
			http.server_shutdown(ctx.server)
			return
		}

		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil {
			http.server_shutdown(ctx.server)
			return
		}
		defer curl.easy_cleanup(handle)

		ping_url := fmt.ctprintf("http://127.0.0.1:%d/ping", endpoint.port)
		ctx.ping_setopt_ok =
			curl.easy_setopt(handle, .URL, ping_url) == .E_OK &&
			curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_response) == .E_OK &&
			curl.easy_setopt(handle, .WRITEDATA, &ctx.ping_res) == .E_OK
		if !ctx.ping_setopt_ok {
			http.server_shutdown(ctx.server)
			return
		}

		ctx.ping_perform_err = curl.easy_perform(handle)
		ctx.ping_getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &ctx.ping_res.status)

		shutdown_thread := thread.create_and_start_with_data(ctx, proc(data: rawptr) {
			ctx := (^Shutdown_Test_Context)(data)
			sync.one_shot_event_wait(&ctx.srv.slow_started)
			ctx.shutdown_started_at = time.now()
			http.server_shutdown(ctx.server)
		})
		defer {
			sync.one_shot_event_signal(&ctx.srv.slow_started)
			thread.join(shutdown_thread)
			thread.destroy(shutdown_thread)
		}

		slow_url := fmt.ctprintf("http://127.0.0.1:%d/slow", endpoint.port)
		ctx.slow_setopt_ok =
			curl.easy_setopt(handle, .URL, slow_url) == .E_OK &&
			curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_response) == .E_OK &&
			curl.easy_setopt(handle, .WRITEDATA, &ctx.slow_res) == .E_OK &&
			curl.easy_setopt(handle, .HEADERFUNCTION, curl_check_conn_close_header) == .E_OK &&
			curl.easy_setopt(handle, .HEADERDATA, &ctx.slow_saw_conn_close) == .E_OK
		if !ctx.slow_setopt_ok {
			return
		}

		ctx.slow_perform_err = curl.easy_perform(handle)
		ctx.slow_getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &ctx.slow_res.status)
	})

	http._serve(&server)
	serve_finished_at := time.now()
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, ctx.endpoint_err, nil) { return }
	if !testing.expect_value(t, ctx.idle_dial_err, nil) { return }
	if !testing.expect_value(t, ctx.stalled_dial_err, nil) { return }
	if !testing.expect_value(t, ctx.stalled_send_err, nil) { return }
	if !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	// 1. Warmup request on keep-alive connection succeeds.
	testing.expect(t, ctx.ping_setopt_ok, "ping: setopt failed")
	testing.expectf(t, ctx.ping_perform_err == .E_OK, "ping: curl failed: %s", curl.easy_strerror(ctx.ping_perform_err))
	testing.expect_value(t, ctx.ping_getinfo_err, curl.code.E_OK)
	testing.expect_value(t, ctx.ping_res.status, c.long(200))
	testing.expect_value(t, string(ctx.ping_res.body[:]), "pong")

	// 2. In-flight request overlapping with server_shutdown finishes with 200, Connection: close, and body.
	testing.expect(t, ctx.slow_setopt_ok, "slow: setopt failed")
	testing.expectf(t, ctx.slow_perform_err == .E_OK, "slow: curl failed: %s", curl.easy_strerror(ctx.slow_perform_err))
	testing.expect_value(t, ctx.slow_getinfo_err, curl.code.E_OK)
	testing.expect_value(t, ctx.slow_res.status, c.long(200))
	testing.expect_value(t, string(ctx.slow_res.body[:]), "slow-ok")
	testing.expect(t, ctx.slow_saw_conn_close, "expected in-flight response during shutdown to include Connection: close")

	// 3. Stalled active connection keeps shutdown waiting until its request_quota expires with 408.
	shutdown_elapsed := time.diff(ctx.shutdown_started_at, serve_finished_at)
	testing.expect(t, shutdown_elapsed >= 100 * time.Millisecond, "expected shutdown to wait for request_quota on stalled active connection")
	testing.expect(t, shutdown_elapsed < 2 * time.Second, "expected shutdown not to hang past request_quota timeout")

	// 4. Idle connection closes immediately; stalled connection receives 408 Request Timeout and closes.
	eof_buf: [16]byte
	idle_n, idle_recv_err := net.recv_tcp(ctx.idle_sock, eof_buf[:])
	testing.expect(t, idle_n == 0 || idle_recv_err != nil, "expected idle socket to be closed by server shutdown")

	_ = net.set_option(ctx.stalled_sock, .Receive_Timeout, 2 * time.Second)
	stalled_buf: [512]byte
	stalled_total := 0
	for stalled_total < len(stalled_buf) {
		n, err := net.recv_tcp(ctx.stalled_sock, stalled_buf[stalled_total:])
		if n <= 0 || err != nil {
			break
		}
		stalled_total += n
	}
	testing.expect(t, strings.has_prefix(string(stalled_buf[:stalled_total]), "HTTP/1.1 408 "), "expected stalled socket to receive 408 Request Timeout before closing")

	// 5. thread_initializer ran before request handling and thread_deinitializer cleaned up on shutdown.
	testing.expect(t, srv_state.handler_saw_tls, "expected handler to see thread_initializer state")
	testing.expect(t, _tls_test_buf == nil, "expected thread_deinitializer to clean up thread-local state")
}

File_Case_Result :: struct {
	setopt_ok:        bool,
	perform_err:      curl.code,
	getinfo_err:      curl.code,
	ct_err:           curl.code,
	has_content_type: bool,
	content_type_buf: [128]byte,
	content_type_len: int,
	location_buf:     [128]byte,
	location_len:     int,
	response:         Curl_Response,
}

curl_capture_location_header :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
	context = runtime.default_context()

	real_size := int(size) * int(nmemb)
	line := strings.trim_space(string(contents[:real_size]))
	if colon := strings.index_byte(line, ':'); colon > 0 {
		if strings.equal_fold(line[:colon], "location") {
			res := (^File_Case_Result)(userp)
			val := strings.trim_space(line[colon+1:])
			res.location_len = copy(res.location_buf[:], val)
		}
	}

	return c.size_t(real_size)
}

File_Test_Context :: struct {
	server:            ^http.Server,
	endpoint_err:      net.Socket_Info_Error,
	handle_ok:         bool,
	readme:            File_Case_Result,
	override:          File_Case_Result,
	license:           File_Case_Result,
	via_file:          File_Case_Result,
	content:           File_Case_Result,
	dir_file:          File_Case_Result,
	dir_escape:        File_Case_Result,
	dir_index:         File_Case_Result,
	dir_path:          File_Case_Result,
	dir_root_redirect: File_Case_Result,
	dir_sub_redirect:  File_Case_Result,
	dir_encoded_slash: File_Case_Result,
}

@(test)
test_http2_respond_file_content_type_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/readme", proc(ctx: ^http.Ctx) {
		http.respond_file_path(&ctx.res, "core/http2/README.md")
	})
	http.route_get(&r, "/override", proc(ctx: ^http.Ctx) {
		http.set_header(&ctx.res, "Content-Type", "application/custom")
		http.respond_file_path(&ctx.res, "core/http2/README.md")
	})
	http.route_get(&r, "/license", proc(ctx: ^http.Ctx) {
		http.respond_file_path(&ctx.res, "core/http/LICENSE")
	})
	http.route_get(&r, "/dir-only", proc(ctx: ^http.Ctx) {
		http.respond_file_path(&ctx.res, "core/http2")
	})
	http.route_get(&r, "/content", proc(ctx: ^http.Ctx) {
		http.respond_file_content(&ctx.res, "hello.json", transmute([]byte)string(`{"ok":true}`))
	})
	http.route_get(&r, "/static/*", proc(ctx: ^http.Ctx) {
		http.respond_dir(&ctx.res, "core/http2", http.route_suffix(ctx))
	})
	http.route_get(&r, "/static", proc(ctx: ^http.Ctx) {
		http.respond_dir(&ctx.res, "core/http2", http.route_suffix(ctx))
	})
	http.route_get(&r, "/old/*", proc(ctx: ^http.Ctx) {
		http.respond_dir(&ctx.res, "core/http", http.route_suffix(ctx))
	})
	http.route_get(&r, "/old", proc(ctx: ^http.Ctx) {
		http.respond_dir(&ctx.res, "core/http", http.route_suffix(ctx))
	})
	http.route_get(&r, "/file", proc(ctx: ^http.Ctx) {
		f, err := os.open("core/http2/README.md")
		if err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(&ctx.res)
			return
		}
		File_Handle :: distinct ^os.File
		http.context_add(ctx, File_Handle(f))
		http.response_defer(ctx, proc(ctx: ^http.Ctx) {
			fp := http.context_get(ctx, File_Handle)^
			os.close((^os.File)(fp))
		})
		if assoc_err := http.respond_file(&ctx.res, f); assoc_err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(&ctx.res)
		}
	})

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18085,
		thread_count = 1,
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	ctx := File_Test_Context{server = &server}
	defer delete(ctx.readme.response.body)
	defer delete(ctx.override.response.body)
	defer delete(ctx.license.response.body)
	defer delete(ctx.via_file.response.body)
	defer delete(ctx.content.response.body)
	defer delete(ctx.dir_file.response.body)
	defer delete(ctx.dir_escape.response.body)
	defer delete(ctx.dir_index.response.body)
	defer delete(ctx.dir_path.response.body)
	defer delete(ctx.dir_root_redirect.response.body)
	defer delete(ctx.dir_sub_redirect.response.body)
	defer delete(ctx.dir_encoded_slash.response.body)

	client_thread := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		ctx := (^File_Test_Context)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil {
			return
		}

		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil {
			return
		}
		defer curl.easy_cleanup(handle)

		do_get :: proc(handle: ^curl.CURL, port: int, path: string, res: ^File_Case_Result) {
			url := fmt.ctprintf("http://127.0.0.1:%d%s", port, path)
			res.setopt_ok =
				curl.easy_setopt(handle, .URL, url) == .E_OK &&
				curl.easy_setopt(handle, .PATH_AS_IS, c.long(1)) == .E_OK &&
				curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_response) == .E_OK &&
				curl.easy_setopt(handle, .WRITEDATA, &res.response) == .E_OK &&
				curl.easy_setopt(handle, .HEADERFUNCTION, curl_capture_location_header) == .E_OK &&
				curl.easy_setopt(handle, .HEADERDATA, res) == .E_OK
			if !res.setopt_ok {
				return
			}

			res.perform_err = curl.easy_perform(handle)
			res.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.response.status)
			ct: cstring
			res.ct_err = curl.easy_getinfo(handle, .CONTENT_TYPE, &ct)
			if ct != nil {
				res.has_content_type = true
				res.content_type_len = copy(res.content_type_buf[:], string(ct))
			}
		}

		do_get(handle, endpoint.port, "/readme",                      &ctx.readme)
		do_get(handle, endpoint.port, "/override",                    &ctx.override)
		do_get(handle, endpoint.port, "/license",                     &ctx.license)
		do_get(handle, endpoint.port, "/file",                        &ctx.via_file)
		do_get(handle, endpoint.port, "/content",                     &ctx.content)
		do_get(handle, endpoint.port, "/static/README.md",            &ctx.dir_file)
		do_get(handle, endpoint.port, "/static/%2e%2e/http/LICENSE",  &ctx.dir_escape)
		do_get(handle, endpoint.port, "/static/",                     &ctx.dir_index)
		do_get(handle, endpoint.port, "/dir-only",                    &ctx.dir_path)
		do_get(handle, endpoint.port, "/static?v=1",                  &ctx.dir_root_redirect)
		do_get(handle, endpoint.port, "/old/dns",                     &ctx.dir_sub_redirect)
		do_get(handle, endpoint.port, "/static/sub%2fREADME.md",      &ctx.dir_encoded_slash)
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, ctx.endpoint_err, nil) { return }
	if !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	check_case :: proc(t: ^testing.T, name: string, res: ^File_Case_Result, expect_status: c.long, expect_has_ct: bool, expect_ct: string, expect_prefix: string) {
		testing.expectf(t, res.setopt_ok, "%s: setopt failed", name)
		testing.expectf(t, res.perform_err == .E_OK, "%s: curl failed: %s", name, curl.easy_strerror(res.perform_err))
		testing.expect_value(t, res.getinfo_err, curl.code.E_OK)
		testing.expect_value(t, res.ct_err, curl.code.E_OK)
		testing.expect_value(t, res.response.status, expect_status)
		testing.expect_value(t, res.has_content_type, expect_has_ct)
		if expect_has_ct {
			testing.expect_value(t, string(res.content_type_buf[:res.content_type_len]), expect_ct)
		}
		testing.expectf(t, strings.has_prefix(string(res.response.body[:]), expect_prefix), "%s: unexpected file body prefix", name)
	}

	check_case(t, "readme",            &ctx.readme,            200, true,  "text/markdown",      "# core/http2")
	check_case(t, "override",          &ctx.override,          200, true,  "application/custom", "# core/http2")
	check_case(t, "license",           &ctx.license,           200, false, "",                   "")
	check_case(t, "via_file",          &ctx.via_file,          200, true,  "text/markdown",      "# core/http2")
	check_case(t, "content",           &ctx.content,           200, true,  "application/json",   `{"ok":true}`)
	check_case(t, "dir_file",          &ctx.dir_file,          200, true,  "text/markdown",      "# core/http2")
	check_case(t, "dir_escape",        &ctx.dir_escape,        404, false, "",                   "")
	check_case(t, "dir_index",         &ctx.dir_index,         404, false, "",                   "")
	check_case(t, "dir_path",          &ctx.dir_path,          404, false, "",                   "")
	check_case(t, "dir_root_redirect", &ctx.dir_root_redirect, 307, false, "",                   "")
	check_case(t, "dir_sub_redirect",  &ctx.dir_sub_redirect,  307, false, "",                   "")
	check_case(t, "dir_encoded_slash", &ctx.dir_encoded_slash, 404, false, "",                   "")
	testing.expect_value(t, string(ctx.dir_root_redirect.location_buf[:ctx.dir_root_redirect.location_len]), "/static/?v=1")
	testing.expect_value(t, string(ctx.dir_sub_redirect.location_buf[:ctx.dir_sub_redirect.location_len]),   "/old/dns/")
	testing.expect(t, len(ctx.license.response.body) > 0, "expected non-empty LICENSE file body")
}

@(test)
test_http2_respond_helpers_and_chunked_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	Json_Payload :: struct {
		msg:   string `json:"msg"`,
		count: int    `json:"count"`,
	}

	Chunk_Chain_State :: struct {
		step: int,
	}

	on_chunk_chain :: proc(c: ^http.Connection, err: http.Send_Error) {
		if err != nil { return }
		st := http.context_get(&c.ctx, Chunk_Chain_State)
		st.step += 1
		switch st.step {
		case 1:
			http.send_chunk(&c.res, {nil, transmute([]byte)string("two-")})
			http.send_chunk(&c.res, {transmute([]byte)string("three")}, on_chunk_chain)
		case 2:
			http.respond(&c.res)
		}
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/plain", proc(ctx: ^http.Ctx) {
		http.respond_plain(&ctx.res, "hello plain")
	})
	http.route_get(&r, "/html", proc(ctx: ^http.Ctx) {
		http.respond_html(&ctx.res, "<h1>hello</h1>")
	})
	http.route_get(&r, "/json", proc(ctx: ^http.Ctx) {
		if err := http.respond_json(&ctx.res, Json_Payload{msg = "ok", count = 3}); err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond_plain(&ctx.res, "marshal error")
		}
	})
	http.route_get(&r, "/json-err", proc(ctx: ^http.Ctx) {
		bad := proc() {}
		if err := http.respond_json(&ctx.res, bad); err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond_plain(&ctx.res, "marshal error")
		}
	})
	http.route_get(&r, "/chunks", proc(ctx: ^http.Ctx) {
		http.context_add(ctx, Chunk_Chain_State{})
		http.send_chunk(&ctx.res, {transmute([]byte)string("one-")}, on_chunk_chain)
	})

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18086,
		thread_count = 1,
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	Respond_Helpers_Context :: struct {
		server:          ^http.Server,
		endpoint_err:    net.Socket_Info_Error,
		handle_ok:       bool,
		plain:           File_Case_Result,
		html:            File_Case_Result,
		json_get:        File_Case_Result,
		json_head:       File_Case_Result,
		json_err:        File_Case_Result,
		chunks:          File_Case_Result,
		chunks_head:     File_Case_Result,
		after_keepalive: File_Case_Result,
	}

	ctx := Respond_Helpers_Context{server = &server}
	defer delete(ctx.plain.response.body)
	defer delete(ctx.html.response.body)
	defer delete(ctx.json_get.response.body)
	defer delete(ctx.json_head.response.body)
	defer delete(ctx.json_err.response.body)
	defer delete(ctx.chunks.response.body)
	defer delete(ctx.chunks_head.response.body)
	defer delete(ctx.after_keepalive.response.body)

	client_thread := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		ctx := (^Respond_Helpers_Context)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil {
			return
		}

		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil {
			return
		}
		defer curl.easy_cleanup(handle)

		do_req :: proc(handle: ^curl.CURL, port: int, path: string, is_head: bool, res: ^File_Case_Result) {
			url := fmt.ctprintf("http://127.0.0.1:%d%s", port, path)
			method_ok := curl.easy_setopt(handle, .NOBODY, c.long(1)) == .E_OK if is_head else (
				curl.easy_setopt(handle, .NOBODY, c.long(0)) == .E_OK &&
				curl.easy_setopt(handle, .HTTPGET, c.long(1)) == .E_OK
			)
			res.setopt_ok = method_ok &&
				curl.easy_setopt(handle, .URL, url) == .E_OK &&
				curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_response) == .E_OK &&
				curl.easy_setopt(handle, .WRITEDATA, &res.response) == .E_OK
			if !res.setopt_ok {
				return
			}

			res.perform_err = curl.easy_perform(handle)
			res.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.response.status)
			ct: cstring
			res.ct_err = curl.easy_getinfo(handle, .CONTENT_TYPE, &ct)
			if ct != nil {
				res.has_content_type = true
				res.content_type_len = copy(res.content_type_buf[:], string(ct))
			}
		}

		do_req(handle, endpoint.port, "/plain",    false, &ctx.plain)
		do_req(handle, endpoint.port, "/html",     false, &ctx.html)
		do_req(handle, endpoint.port, "/json",     false, &ctx.json_get)
		do_req(handle, endpoint.port, "/json",     true,  &ctx.json_head)
		do_req(handle, endpoint.port, "/json-err", false, &ctx.json_err)
		do_req(handle, endpoint.port, "/chunks",   false, &ctx.chunks)
		do_req(handle, endpoint.port, "/chunks",   true,  &ctx.chunks_head)
		do_req(handle, endpoint.port, "/plain",    false, &ctx.after_keepalive)
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, ctx.endpoint_err, nil) { return }
	if !testing.expect(t, ctx.handle_ok, "curl.easy_init failed") { return }

	check :: proc(t: ^testing.T, name: string, res: ^File_Case_Result, expect_status: c.long, expect_has_ct: bool, expect_ct: string, expect_body: string) {
		testing.expectf(t, res.setopt_ok, "%s: setopt failed", name)
		testing.expectf(t, res.perform_err == .E_OK, "%s: curl failed: %s", name, curl.easy_strerror(res.perform_err))
		testing.expect_value(t, res.getinfo_err, curl.code.E_OK)
		testing.expect_value(t, res.ct_err, curl.code.E_OK)
		testing.expect_value(t, res.response.status, expect_status)
		testing.expect_value(t, res.has_content_type, expect_has_ct)
		if expect_has_ct {
			testing.expect_value(t, string(res.content_type_buf[:res.content_type_len]), expect_ct)
		}
		testing.expect_value(t, string(res.response.body[:]), expect_body)
	}

	check(t, "plain",           &ctx.plain,           200, true,  "text/plain",       "hello plain")
	check(t, "html",            &ctx.html,            200, true,  "text/html",        "<h1>hello</h1>")
	check(t, "json_get",        &ctx.json_get,        200, true,  "application/json", `{"msg":"ok","count":3}`)
	check(t, "json_head",       &ctx.json_head,       200, true,  "application/json", "")
	check(t, "json_err",        &ctx.json_err,        500, true,  "text/plain",       "marshal error")
	check(t, "chunks",          &ctx.chunks,          200, false, "",                 "one-two-three")
	check(t, "chunks_head",     &ctx.chunks_head,     200, false, "",                 "")
	check(t, "after_keepalive", &ctx.after_keepalive, 200, true,  "text/plain",       "hello plain")
}

@(test)
test_http2_accept_error_recovery_and_oom_cleanup :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	listen_sock, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 18087})
	if !testing.expect_value(t, listen_err, nil) {
		return
	}
	defer {
		closed: bool
		nbio.close_poly(listen_sock, &closed, proc(op: ^nbio.Operation, closed: ^bool) { closed^ = true })
		nbio.run_until(&closed)
	}

	s := http.make_server({})
	thread := http.Server_Thread{s = &s, id = 1}
	s.socket = listen_sock

	// 1. Transient error (.Aborted) immediately re-arms .Accept.
	{
		op: nbio.Operation
		op.accept.err = .Aborted
		http._on_accept(&op, &thread)
		testing.expect(t, thread.curr_accept != nil && thread.curr_accept.type == .Accept, "expected .Aborted to immediately re-arm accept")
		if thread.curr_accept != nil {
			nbio.remove(thread.curr_accept)
			thread.curr_accept = nil
		}
		nbio.tick(timeout = 0)
	}

	// 2. Resource error (.Insufficient_Resources) schedules backoff timeout in curr_accept and then re-arms .Accept.
	{
		op: nbio.Operation
		op.accept.err = .Insufficient_Resources
		http._on_accept(&op, &thread)
		testing.expect(t, thread.curr_accept != nil && thread.curr_accept.type == .Timeout, "expected .Insufficient_Resources to schedule backoff timer")

		timed_out := false
		guard := nbio.timeout_poly(2 * time.Second, &timed_out, proc(_: ^nbio.Operation, timed_out: ^bool) {
			timed_out^ = true
		})
		for !timed_out && (thread.curr_accept == nil || thread.curr_accept.type != .Accept) {
			nbio.tick()
		}
		if !timed_out {
			nbio.remove(guard)
		}
		testing.expect(t, !timed_out, "timed out waiting for accept backoff timer to re-arm accept")
		testing.expect(t, thread.curr_accept != nil && thread.curr_accept.type == .Accept, "expected backoff timer callback to re-arm accept")
		if thread.curr_accept != nil {
			nbio.remove(thread.curr_accept)
			thread.curr_accept = nil
		}
		nbio.tick(timeout = 0)
	}

	// 3. Permanent error (.Not_Listening) stops the accept loop cleanly.
	{
		op: nbio.Operation
		op.accept.err = .Not_Listening
		prev_logger := context.logger
		context.logger = log.nil_logger()
		http._on_accept(&op, &thread)
		context.logger = prev_logger
		testing.expect(t, thread.curr_accept == nil, "expected fatal accept error not to re-arm accept")
	}

	// 4. xar.push OOM closes accepted client socket (peer sees EOF) while keeping accept loop armed.
	{
		endpoint, endpoint_err := nbio.bound_endpoint(listen_sock)
		if !testing.expect_value(t, endpoint_err, nil) {
			return
		}

		Accept_State :: struct {
			done:   bool,
			err:    nbio.Accept_Error,
			client: nbio.TCP_Socket,
			ep:     nbio.Endpoint,
		}
		Dial_State :: struct {
			done: bool,
			err:  nbio.Network_Error,
			sock: nbio.TCP_Socket,
		}
		accept_st: Accept_State
		dial_st: Dial_State

		nbio.accept_poly(listen_sock, &accept_st, proc(op: ^nbio.Operation, st: ^Accept_State) {
			st.err    = op.accept.err
			st.client = op.accept.client
			st.ep     = op.accept.client_endpoint
			st.done   = true
		})
		nbio.dial_poly(endpoint, &dial_st, proc(op: ^nbio.Operation, st: ^Dial_State) {
			st.err  = op.dial.err
			st.sock = op.dial.socket
			st.done = true
		})
		for !accept_st.done || !dial_st.done {
			nbio.tick()
		}
		if !testing.expect_value(t, accept_st.err, nil) || !testing.expect_value(t, dial_st.err, nil) {
			return
		}
		defer {
			closed: bool
			nbio.close_poly(dial_st.sock, &closed, proc(op: ^nbio.Operation, closed: ^bool) { closed^ = true })
			nbio.run_until(&closed)
		}

		oom_alloc := runtime.Allocator{
			procedure = proc(allocator_data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, location := #caller_location) -> (data: []byte, err: runtime.Allocator_Error) {
				if mode == .Free || mode == .Free_All {
					return nil, nil
				}
				return nil, .Out_Of_Memory
			},
		}
		oom_thread := http.Server_Thread{s = &s, id = 2}
		xar.init(&oom_thread.connections, oom_alloc)
		defer xar.freelist_destroy(&oom_thread.connections)

		fake_op: nbio.Operation
		fake_op.accept.client          = accept_st.client
		fake_op.accept.client_endpoint = accept_st.ep

		prev_logger := context.logger
		context.logger = log.nil_logger()
		http._on_accept(&fake_op, &oom_thread)
		context.logger = prev_logger

		testing.expect(t, oom_thread.curr_accept != nil && oom_thread.curr_accept.type == .Accept, "expected OOM on xar.push to keep accept armed")
		if oom_thread.curr_accept != nil {
			nbio.remove(oom_thread.curr_accept)
			oom_thread.curr_accept = nil
		}

		// Peer socket should immediately observe EOF/closed because _on_accept closed accept_st.client.
		Recv_State :: struct {
			done:     bool,
			received: int,
			err:      nbio.Recv_Error,
		}
		recv_st: Recv_State
		buf: [16]byte
		nbio.recv_poly(dial_st.sock, {buf[:]}, &recv_st, proc(op: ^nbio.Operation, st: ^Recv_State) {
			st.received = op.recv.received
			st.err      = op.recv.err
			st.done     = true
		}, timeout = time.Second)
		for !recv_st.done {
			nbio.tick()
		}
		testing.expect(t, recv_st.received == 0 && recv_st.err != nbio.Recv_Error(nbio.TCP_Recv_Error.Timeout), "expected peer socket to observe closed accepted connection")
	}
}

@(test)
test_http2_dead_socket_send_error_skips_graceful_close :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	listen_sock, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 18088})
	if !testing.expect_value(t, listen_err, nil) {
		return
	}
	defer {
		closed: bool
		nbio.close_poly(listen_sock, &closed, proc(_: ^nbio.Operation, closed: ^bool) { closed^ = true })
		nbio.run_until(&closed)
	}

	endpoint, endpoint_err := nbio.bound_endpoint(listen_sock)
	if !testing.expect_value(t, endpoint_err, nil) {
		return
	}

	s := http.make_server({})

	thread := http.Server_Thread{s = &s, id = 1}
	xar.init(&thread.connections, context.allocator)
	prev_td := http.td
	http.td = &thread
	defer {
		nbio.tick(timeout = 0)
		http.td = prev_td
		http._server_thread_free_arenas_destroy(&thread)
		xar.freelist_destroy(&thread.connections)
	}

	make_tcp_pair :: proc(t: ^testing.T, listen_sock: nbio.TCP_Socket, endpoint: nbio.Endpoint) -> (accepted, peer: nbio.TCP_Socket, ok: bool) {
		Accept_State :: struct {
			done:   bool,
			err:    nbio.Accept_Error,
			client: nbio.TCP_Socket,
		}
		Dial_State :: struct {
			done: bool,
			err:  nbio.Network_Error,
			sock: nbio.TCP_Socket,
		}
		a_st: Accept_State
		d_st: Dial_State

		nbio.accept_poly(listen_sock, &a_st, proc(op: ^nbio.Operation, st: ^Accept_State) {
			st.err    = op.accept.err
			st.client = op.accept.client
			st.done   = true
		})
		nbio.dial_poly(endpoint, &d_st, proc(op: ^nbio.Operation, st: ^Dial_State) {
			st.err  = op.dial.err
			st.sock = op.dial.socket
			st.done = true
		})
		for !a_st.done || !d_st.done {
			nbio.tick()
		}
		if !testing.expect_value(t, a_st.err, nil) || !testing.expect_value(t, d_st.err, nil) {
			return
		}
		return a_st.client, d_st.sock, true
	}

	close_socket :: proc(sock: nbio.TCP_Socket) {
		closed: bool
		nbio.close_poly(sock, &closed, proc(_: ^nbio.Operation, closed: ^bool) { closed^ = true })
		nbio.run_until(&closed)
	}

	push_conn :: proc(t: ^testing.T, thread: ^http.Server_Thread, sock: nbio.TCP_Socket) -> ^http.Connection {
		c, push_err := xar.push(&thread.connections, http.Connection{socket = sock})
		testing.expect_value(t, push_err, nil)
		c.transaction_arena = http.get_arena(c)
		c.temp_arena        = http.get_arena(c)
		tx_alloc := http.transaction_allocator(c)
		c._vars.allocator         = tx_alloc
		c.req.headers.allocator  = tx_alloc
		c.res.headers.allocator  = tx_alloc
		c.res._buf.allocator      = tx_alloc
		c.res._deferred.allocator = tx_alloc
		c.scanner.c              = c
		c.scanner.allocator      = &c.transaction_arena
		return c
	}

	active_count :: proc(thread: ^http.Server_Thread) -> int {
		count := 0
		iter := xar.freelist_iterator(&thread.connections)
		for _, _ in xar.freelist_iterate_by_ptr(&iter) {
			count += 1
		}
		return count
	}

	// 1. Dead-socket TCP_Send_Error (.Connection_Closed) skips 500ms drain and destroys immediately.
	{
		accepted, peer, ok := make_tcp_pair(t, listen_sock, endpoint)
		if !ok { return }
		defer close_socket(peer)

		c := push_conn(t, &thread, accepted)
		c.res._state = .Sending
		c.res._sends = 1

		Defer_Flag :: distinct ^bool
		defer_ran := false
		http.context_add(&c.ctx, Defer_Flag(&defer_ran))
		http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {
			flag := http.context_get(ctx, Defer_Flag)^
			(^bool)(flag)^ = true
		})

		op := nbio.Operation{
			type = .Send,
			send = {err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, nil)

		testing.expect_value(t, active_count(&thread), 0)
		testing.expect(t, defer_ran, "expected response_defer to run during immediate connection_destroy")
	}

	// 2. Multiple in-flight sends wait for sends == 0 before destroying immediately.
	{
		accepted, peer, ok := make_tcp_pair(t, listen_sock, endpoint)
		if !ok { return }
		defer close_socket(peer)

		c := push_conn(t, &thread, accepted)
		c.res._state = .Sending
		c.res._sends = 2

		op := nbio.Operation{
			type = .Send,
			send = {err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, nil)
		testing.expect_value(t, active_count(&thread), 1)
		testing.expect_value(t, c.res._sends, 1)
		testing.expect(t, c.res._state == .Error, "expected state to transition to .Error")

		http.on_send(&op, c, nil)
		testing.expect_value(t, active_count(&thread), 0)
	}

	// 3. FS_Error on Send_File (socket still usable) preserves graceful connection_close drain.
	{
		accepted, peer, ok := make_tcp_pair(t, listen_sock, endpoint)
		if !ok { return }
		peer_closed := false
		defer if !peer_closed {
			close_socket(peer)
		}

		c := push_conn(t, &thread, accepted)
		c.res._state = .Sending
		c.res._sends = 1

		op := nbio.Operation{
			type     = .Send_File,
			sendfile = {err = nbio.FS_Error.EOF},
		}
		http.on_send(&op, c, nil)

		testing.expect_value(t, active_count(&thread), 1)
		testing.expect(t, c.curr_recv != nil, "expected connection_close to arm drain recv on non-dead-socket error")

		close_socket(peer)
		peer_closed = true

		timed_out := false
		guard := nbio.timeout_poly(2 * time.Second, &timed_out, proc(_: ^nbio.Operation, timed_out: ^bool) {
			timed_out^ = true
		})
		for !timed_out && active_count(&thread) > 0 {
			nbio.tick()
		}
		if !timed_out {
			nbio.remove(guard)
		}
		testing.expect(t, !timed_out, "timed out waiting for graceful connection_close drain to finish")
		testing.expect_value(t, active_count(&thread), 0)
	}
}

@(test)
test_http2_peer_disconnect_during_inflight_send :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	listen_sock, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 18094})
	if !testing.expect_value(t, listen_err, nil) {
		return
	}
	defer {
		closed: bool
		nbio.close_poly(listen_sock, &closed, proc(_: ^nbio.Operation, closed: ^bool) { closed^ = true })
		nbio.run_until(&closed)
	}

	endpoint, endpoint_err := nbio.bound_endpoint(listen_sock)
	if !testing.expect_value(t, endpoint_err, nil) {
		return
	}

	s := http.make_server({})

	thread := http.Server_Thread{s = &s, id = 1}
	xar.init(&thread.connections, context.allocator)
	prev_td := http.td
	http.td = &thread
	defer {
		nbio.tick(timeout = 0)
		http.td = prev_td
		http._server_thread_free_arenas_destroy(&thread)
		xar.freelist_destroy(&thread.connections)
	}

	Accept_State :: struct {
		done:   bool,
		err:    nbio.Accept_Error,
		client: nbio.TCP_Socket,
	}
	Dial_State :: struct {
		done: bool,
		err:  nbio.Network_Error,
		sock: nbio.TCP_Socket,
	}
	a_st: Accept_State
	d_st: Dial_State

	nbio.accept_poly(listen_sock, &a_st, proc(op: ^nbio.Operation, st: ^Accept_State) {
		st.err    = op.accept.err
		st.client = op.accept.client
		st.done   = true
	})
	nbio.dial_poly(endpoint, &d_st, proc(op: ^nbio.Operation, st: ^Dial_State) {
		st.err  = op.dial.err
		st.sock = op.dial.socket
		st.done = true
	})
	for !a_st.done || !d_st.done {
		nbio.tick()
	}
	if !testing.expect_value(t, a_st.err, nil) || !testing.expect_value(t, d_st.err, nil) {
		return
	}
	peer := d_st.sock
	peer_closed := false
	defer if !peer_closed {
		closed: bool
		nbio.close_poly(peer, &closed, proc(_: ^nbio.Operation, closed: ^bool) { closed^ = true })
		nbio.run_until(&closed)
	}

	c, push_err := xar.push(&thread.connections, http.Connection{socket = a_st.client})
	if !testing.expect_value(t, push_err, nil) {
		return
	}
	c.transaction_arena = http.get_arena(c)
	c.temp_arena        = http.get_arena(c)
	tx_alloc := http.transaction_allocator(c)
	c._vars.allocator         = tx_alloc
	c.req.headers.allocator  = tx_alloc
	c.res.headers.allocator  = tx_alloc
	c.res._buf.allocator      = tx_alloc
	c.res._deferred.allocator = tx_alloc
	c.scanner.c              = c
	c.scanner.allocator      = &c.transaction_arena
	c.req.line               = {method = .Get, target = "/", version = {1, 1}}
	c.req.has_consumed_body  = true
	c.req.quota              = &s.opts.request_quota
	c.res.quota              = &s.opts.response_quota
	http.progression_init(&c.req.progress, http.UNLIMITED_QUOTA)
	http.progression_init(&c.res.progress, http.UNLIMITED_QUOTA)
	c.res.status = .OK
	c.res._state = .Handling

	Flags :: struct {
		sent_ran:  bool,
		defer_ran: bool,
	}
	flags: Flags
	http.context_add(&c.ctx, &flags)
	http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {
		f := http.context_get(ctx, ^Flags)^
		f.defer_ran = true
	})

	payload, payload_err := make([]byte, 8 * mem.Megabyte, tx_alloc)
	if !testing.expect_value(t, payload_err, nil) {
		return
	}

	http.send(&c.res, {payload}, proc(c: ^http.Connection, err: http.Send_Error) {
		f := http.context_get(&c.ctx, ^Flags)^
		f.sent_ran = true
	})
	http.scan_bytes(&c.scanner, 64, proc(c: ^http.Connection, data: []byte) {})

	testing.expect_value(t, c.res._sends, 1)
	testing.expect(t, c.curr_recv != nil, "expected active Recv op to be tracked")

	// Flush submissions once so both the large Send and the Recv are in flight, then send TCP FIN from peer
	// (`nbio.shutdown(.Send)` keeps peer's recv side open so the 8 MiB send stays blocked while `scanner_on_recv` sees EOF).
	nbio.tick(timeout = 10 * time.Millisecond)

	active_count :: proc(thread: ^http.Server_Thread) -> int {
		count := 0
		iter := xar.freelist_iterator(&thread.connections)
		for _, _ in xar.freelist_iterate_by_ptr(&iter) {
			count += 1
		}
		return count
	}

	nbio.shutdown(peer, .Send)

	fin_timeout := false
	fin_guard := nbio.timeout_poly(2 * time.Second, &fin_timeout, proc(_: ^nbio.Operation, timed_out: ^bool) {
		timed_out^ = true
	})
	for !fin_timeout && active_count(&thread) > 0 && c.curr_recv != nil {
		nbio.tick()
	}
	if !fin_timeout {
		nbio.remove(fin_guard)
	}
	testing.expect(t, !fin_timeout, "timed out waiting for scanner_on_recv to receive peer FIN")
	testing.expect_value(t, active_count(&thread), 1)
	testing.expect(t, c.res._state == .Error, "expected state to transition to .Error on disconnect during send")
	testing.expect(t, !flags.defer_ran, "expected connection_destroy/response_defer to wait for in-flight send")

	// Now close peer so the blocked send finishes/errors and completes teardown.
	closed: bool
	nbio.close_poly(peer, &closed, proc(_: ^nbio.Operation, closed: ^bool) { closed^ = true })
	nbio.run_until(&closed)
	peer_closed = true

	timed_out := false
	guard := nbio.timeout_poly(2 * time.Second, &timed_out, proc(_: ^nbio.Operation, timed_out: ^bool) {
		timed_out^ = true
	})
	for !timed_out && active_count(&thread) > 0 {
		nbio.tick()
	}
	if !timed_out {
		nbio.remove(guard)
	}
	testing.expect(t, !timed_out, "timed out waiting for connection teardown after send completion")
	testing.expect_value(t, active_count(&thread), 0)
	testing.expect(t, flags.sent_ran, "expected on_sent callback to run cleanly before teardown")
	testing.expect(t, flags.defer_ran, "expected response_defer to run once on final teardown")
}

@(test)
test_http2_temp_allocator_binding_and_tick_reset :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	discard_write :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
		return size * nmemb
	}

	// 1. Verify response_defer binds temp_allocator(c) across keep-alive, file-path open/stat/error,
	//    and connection_close paths, and verify _server_thread_serve resets temp_allocator per tick.
	{
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
			defer_calls:   int,
			defer_matched: int,
		}
		srv_state: Temp_Check_State

		r: http.Router
		defer http.router_destroy(r)

		register_defer_check :: proc(ctx: ^http.Ctx, st: ^Temp_Check_State) {
			http.context_add(ctx, st)
			http.response_defer(ctx, proc(ctx: ^http.Ctx) {
				st := http.context_get(ctx, ^Temp_Check_State)^
				c := http.connection_of_response(&ctx.res)
				st.defer_calls += 1
				if context.temp_allocator.data == http.temp_allocator(c).data {
					st.defer_matched += 1
				}
				scratch, serr := make([]byte, 64, context.temp_allocator)
				if serr == nil && len(scratch) == 64 {
					scratch[0] = 1
				}
			})
		}

		http.route_get(&r, "/ok", http.Handler{
			user_data = &srv_state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				register_defer_check(ctx, (^Temp_Check_State)(h.user_data))
				http.respond_bytes(&ctx.res, transmute([]byte)string("ok"))
			},
		})
		http.route_get(&r, "/file", http.Handler{
			user_data = &srv_state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				register_defer_check(ctx, (^Temp_Check_State)(h.user_data))
				http.respond_file_path(&ctx.res, "core/http2/README.md")
			},
		})
		http.route_get(&r, "/missing", http.Handler{
			user_data = &srv_state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				register_defer_check(ctx, (^Temp_Check_State)(h.user_data))
				http.respond_file_path(&ctx.res, "core/http2/__does_not_exist__")
			},
		})
		http.route_get(&r, "/close", http.Handler{
			user_data = &srv_state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				register_defer_check(ctx, (^Temp_Check_State)(h.user_data))
				http.set_header(&ctx.res, "connection", "close")
				http.respond_bytes(&ctx.res, transmute([]byte)string("bye"))
			},
		})

		s := http.make_server(http.Server_Options{
			address      = nbio.IP4_Loopback,
			port         = 0,
			thread_count = 1,
			handler      = http.router(&r),
		})
		setup_err := http._setup(&s)
		if !testing.expect_value(t, setup_err, nil) {
			http._destroy(&s)
			return
		}

		Client_Ctx :: struct {
			s:            ^http.Server,
			endpoint_err: net.Socket_Info_Error,
			handle_ok:    bool,
			perform_errs: [4]curl.code,
			statuses:     [4]c.long,
		}
		client_ctx := Client_Ctx{s = &s}

		client_thread := thread.create_and_start_with_data(&client_ctx, proc(data: rawptr) {
			ctx := (^Client_Ctx)(data)
			defer http.server_shutdown(ctx.s)

			endpoint, endpoint_err := nbio.bound_endpoint(ctx.s.socket)
			ctx.endpoint_err = endpoint_err
			if endpoint_err != nil {
				return
			}

			handle := curl.easy_init()
			ctx.handle_ok = handle != nil
			if handle == nil {
				return
			}
			defer curl.easy_cleanup(handle)

			curl.easy_setopt(handle, .WRITEFUNCTION, discard_write)

			paths := [4]string{"/ok", "/file", "/missing", "/close"}
			for p, i in paths {
				url := fmt.ctprintf("http://127.0.0.1:%d%s", endpoint.port, p)
				curl.easy_setopt(handle, .URL, url)
				ctx.perform_errs[i] = curl.easy_perform(handle)
				curl.easy_getinfo(handle, .RESPONSE_CODE, &ctx.statuses[i])
			}
		})

		http._serve(&s)
		thread.join(client_thread)
		thread.destroy(client_thread)
		http._destroy(&s)

		testing.expect_value(t, client_ctx.endpoint_err, nil)
		testing.expect(t, client_ctx.handle_ok, "expected curl handle")
		testing.expect_value(t, client_ctx.perform_errs, [4]curl.code{.E_OK, .E_OK, .E_OK, .E_OK})
		testing.expect_value(t, client_ctx.statuses, [4]c.long{200, 200, 404, 200})
		testing.expect_value(t, srv_state.defer_calls, 4)
		testing.expect_value(t, srv_state.defer_matched, 4)
		testing.expect(t, counting.free_all_count > 0, "expected _server_thread_serve to free_all context.temp_allocator across ticks")
	}

	// 2. Multi-threaded server cleans up spawned worker thread's default_temp_allocator cleanly on exit.
	{
		s2 := http.make_server(http.Server_Options{
			address      = nbio.IP4_Loopback,
			port         = 0,
			thread_count = 2,
			handler      = http.handler(proc(ctx: ^http.Ctx) {
				http.set_header(&ctx.res, "connection", "close")
				http.respond_bytes(&ctx.res, transmute([]byte)string("ok"))
			}),
		})
		setup_err := http._setup(&s2)
		if !testing.expect_value(t, setup_err, nil) {
			http._destroy(&s2)
			return
		}

		Client2_Ctx :: struct {
			s:            ^http.Server,
			endpoint_err: net.Socket_Info_Error,
			perform_err:  curl.code,
			status:       c.long,
		}
		client2 := Client2_Ctx{s = &s2}

		client_thread := thread.create_and_start_with_data(&client2, proc(data: rawptr) {
			ctx := (^Client2_Ctx)(data)
			defer http.server_shutdown(ctx.s)

			endpoint, endpoint_err := nbio.bound_endpoint(ctx.s.socket)
			ctx.endpoint_err = endpoint_err
			if endpoint_err != nil {
				return
			}

			handle := curl.easy_init()
			if handle == nil {
				return
			}
			defer curl.easy_cleanup(handle)

			url := fmt.ctprintf("http://127.0.0.1:%d/", endpoint.port)
			curl.easy_setopt(handle, .URL, url)
			curl.easy_setopt(handle, .WRITEFUNCTION, discard_write)
			ctx.perform_err = curl.easy_perform(handle)
			curl.easy_getinfo(handle, .RESPONSE_CODE, &ctx.status)
		})

		http._serve(&s2)
		thread.join(client_thread)
		thread.destroy(client_thread)
		http._destroy(&s2)

		testing.expect_value(t, client2.endpoint_err, nil)
		testing.expect_value(t, client2.perform_err, curl.code.E_OK)
		testing.expect_value(t, client2.status, c.long(200))
	}
}

@(test)
test_http2_free_all_during_inflight_temp_recv :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	listen_sock, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 0})
	if !testing.expect_value(t, listen_err, nil) {
		return
	}
	defer {
		closed: bool
		nbio.close_poly(listen_sock, &closed, proc(_: ^nbio.Operation, closed: ^bool) { closed^ = true })
		nbio.run_until(&closed)
	}

	endpoint, endpoint_err := nbio.bound_endpoint(listen_sock)
	if !testing.expect_value(t, endpoint_err, nil) {
		return
	}

	s := http.make_server({})

	thread := http.Server_Thread{s = &s, id = 1}
	xar.init(&thread.connections, context.allocator)
	prev_td := http.td
	http.td = &thread
	defer {
		nbio.tick(timeout = 0)
		http.td = prev_td
		http._server_thread_free_arenas_destroy(&thread)
		xar.freelist_destroy(&thread.connections)
	}

	Accept_State :: struct {
		done:   bool,
		err:    nbio.Accept_Error,
		client: nbio.TCP_Socket,
	}
	Dial_State :: struct {
		done: bool,
		err:  nbio.Network_Error,
		sock: nbio.TCP_Socket,
	}
	a_st: Accept_State
	d_st: Dial_State

	nbio.accept_poly(listen_sock, &a_st, proc(op: ^nbio.Operation, st: ^Accept_State) {
		st.err    = op.accept.err
		st.client = op.accept.client
		st.done   = true
	})
	nbio.dial_poly(endpoint, &d_st, proc(op: ^nbio.Operation, st: ^Dial_State) {
		st.err  = op.dial.err
		st.sock = op.dial.socket
		st.done = true
	})
	for !a_st.done || !d_st.done {
		nbio.tick()
	}
	if !testing.expect_value(t, a_st.err, nil) || !testing.expect_value(t, d_st.err, nil) {
		return
	}
	peer := d_st.sock
	defer {
		closed: bool
		nbio.close_poly(peer, &closed, proc(_: ^nbio.Operation, closed: ^bool) { closed^ = true })
		nbio.run_until(&closed)
	}

	c, push_err := xar.push(&thread.connections, http.Connection{socket = a_st.client})
	if !testing.expect_value(t, push_err, nil) {
		return
	}
	c_destroyed := false
	defer if !c_destroyed {
		http._connection_destroy(c)
	}

	c.transaction_arena = http.get_arena(c)
	c.temp_arena        = http.get_arena(c)
	tx_alloc := http.transaction_allocator(c)
	c._vars.allocator         = tx_alloc
	c.req.headers.allocator  = tx_alloc
	c.res.headers.allocator  = tx_alloc
	c.res._buf.allocator      = tx_alloc
	c.res._deferred.allocator = tx_alloc
	c.scanner.c              = c
	c.scanner.allocator      = &c.transaction_arena
	c.req.quota              = &s.opts.request_quota
	c.res.quota              = &s.opts.response_quota
	http.progression_init(&c.req.progress, http.UNLIMITED_QUOTA)
	http.progression_init(&c.res.progress, http.UNLIMITED_QUOTA)
	c.res._state = .Sending

	Frame_State :: struct {
		got:     [8]byte,
		got_len: int,
		called:  bool,
	}
	frame_state: Frame_State
	http.context_add(&c.ctx, &frame_state)

	http.scan_temp_bytes(&c.scanner, 8, proc(c: ^http.Connection, data: []byte) {
		st := http.context_get(&c.ctx, ^Frame_State)^
		st.called  = true
		st.got_len = copy(st.got[:], data)
	})

	testing.expect(t, c.curr_recv != nil, "expected active recv op in flight")
	testing.expect(t, c.scanner.allocator == &c.temp_arena, "expected scanner buffer allocated in temp_arena")

	orig_buf_ptr := raw_data(c.scanner.buf)
	orig_block   := c.temp_arena.tail

	nbio.tick(timeout = 10 * time.Millisecond)

	scratch1, err1 := make([]byte, 128, http.temp_allocator(c))
	testing.expect_value(t, err1, nil)
	scratch1[0] = 1
	scratch2, err2 := make([]byte, 5000, http.temp_allocator(c))
	testing.expect_value(t, err2, nil)
	scratch2[0] = 2
	testing.expect(t, c.temp_arena.tail != orig_block, "expected overflow block pushed into temp_arena")

	free_all(http.temp_allocator(c))

	testing.expect(t, raw_data(c.scanner.buf) == orig_buf_ptr, "expected scanner buffer pointer preserved across free_all")
	testing.expect(t, c.temp_arena.tail == orig_block, "expected pinned block retained as tail")
	testing.expect(t, orig_block.prev == nil, "expected overflow block unlinked")
	testing.expect(t, thread.free_arenas[1] != nil, "expected 8 KiB overflow block returned to thread freelist")
	testing.expect(t, sanitizer.address_region_is_poisoned(c.scanner.buf) == nil, "expected scanner buffer unpoisoned")

	Send_State :: struct {
		done: bool,
		err:  nbio.TCP_Send_Error,
	}
	s_st: Send_State
	payload := transmute([]byte)string("abcdefgh")
	nbio.send_poly(peer, {payload}, &s_st, proc(op: ^nbio.Operation, st: ^Send_State) {
		st.err  = op.send.err.(nbio.TCP_Send_Error) or_else nil
		st.done = true
	})

	timed_out := false
	guard := nbio.timeout_poly(2 * time.Second, &timed_out, proc(_: ^nbio.Operation, timed_out: ^bool) {
		timed_out^ = true
	})
	for !timed_out && (!frame_state.called || !s_st.done) {
		nbio.tick()
	}
	if !timed_out {
		nbio.remove(guard)
	}

	testing.expect(t, !timed_out, "timed out waiting for peer send / scanner recv")
	testing.expect_value(t, s_st.err, nil)
	testing.expect(t, frame_state.called, "expected scan_temp_bytes callback to receive peer data")
	testing.expect_value(t, string(frame_state.got[:frame_state.got_len]), "abcdefgh")

	http._connection_destroy(c)
	c_destroyed = true

	active_count :: proc(thread: ^http.Server_Thread) -> int {
		count := 0
		iter := xar.freelist_iterator(&thread.connections)
		for _, _ in xar.freelist_iterate_by_ptr(&iter) {
			count += 1
		}
		return count
	}
	testing.expect_value(t, active_count(&thread), 0)
}

@(test)
test_http2_setup_failure_cleanup_and_worker_join :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	// 1. _setup bind failure on a fresh thread closes any socket state and releases thread event loop.
	{
		holder, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 0})
		if !testing.expect_value(t, listen_err, nil) {
			return
		}
		defer {
			closed: bool
			nbio.close_poly(holder, &closed, proc(_: ^nbio.Operation, closed: ^bool) { closed^ = true })
			nbio.run_until(&closed)
		}

		ep, ep_err := nbio.bound_endpoint(holder)
		if !testing.expect_value(t, ep_err, nil) {
			return
		}

		Bind_Result :: struct {
			allocator:               runtime.Allocator,
			port:                    int,
			setup_err:               http.Server_Error,
			socket_cleared:          bool,
			threads_nil:             bool,
			loop_nil:                bool,
			loop_nil_after_destroy:  bool,
		}
		res := Bind_Result{allocator = context.allocator, port = ep.port}

		worker := thread.create_and_start_with_data(&res, proc(data: rawptr) {
			res := (^Bind_Result)(data)
			context.allocator = res.allocator
			s := http.make_server(http.Server_Options{
				address      = nbio.IP4_Loopback,
				port         = res.port,
				thread_count = 1,
			})
			res.setup_err      = http._setup(&s)
			res.socket_cleared = s.socket == {}
			res.threads_nil    = s.threads == nil
			res.loop_nil       = nbio.current_thread_event_loop() == nil
			http._destroy(&s)
			res.loop_nil_after_destroy = nbio.current_thread_event_loop() == nil
		})
		testing.expect(t, worker != nil, "expected helper thread created")
		thread.destroy(worker)

		testing.expect(t, res.setup_err != nil, "expected _setup to fail when port is already in use")
		testing.expect(t, res.socket_cleared, "expected s.socket cleared on _setup bind failure")
		testing.expect(t, res.threads_nil, "expected s.threads nil on _setup bind failure")
		testing.expect(t, res.loop_nil, "expected thread event loop released on _setup bind failure")
		testing.expect(t, res.loop_nil_after_destroy, "expected _destroy after failed _setup to leave event loop released")
	}

	// 2. _setup OOM during _setup_threads closes s.socket and releases loop.
	{
		OOM_Result :: struct {
			allocator:      runtime.Allocator,
			setup_err:      http.Server_Error,
			socket_cleared: bool,
			threads_nil:    bool,
			loop_nil:       bool,
		}
		res := OOM_Result{allocator = context.allocator}

		worker := thread.create_and_start_with_data(&res, proc(data: rawptr) {
			res := (^OOM_Result)(data)
			context.allocator = res.allocator
			oom_alloc := runtime.Allocator{
				procedure = proc(allocator_data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, location := #caller_location) -> ([]byte, runtime.Allocator_Error) {
					if mode == .Free || mode == .Free_All {
						return nil, nil
					}
					return nil, .Out_Of_Memory
				},
			}
			s := http.make_server(http.Server_Options{
				address      = nbio.IP4_Loopback,
				port         = 18096,
				thread_count = 1,
			}, oom_alloc)

			res.setup_err      = http._setup(&s)
			res.socket_cleared = s.socket == {}
			res.threads_nil    = s.threads == nil
			res.loop_nil       = nbio.current_thread_event_loop() == nil
		})
		testing.expect(t, worker != nil, "expected helper thread created")
		thread.destroy(worker)

		testing.expect_value(t, res.setup_err, http.Server_Error(http.General_Error.Allocation_Failed))
		testing.expect(t, res.socket_cleared, "expected s.socket closed and cleared on _setup_threads OOM")
		testing.expect(t, res.threads_nil, "expected s.threads nil on _setup_threads OOM")
		testing.expect(t, res.loop_nil, "expected thread event loop released on _setup_threads OOM")
	}

	// 3. Multi-threaded _setup followed by _destroy without _serve joins worker threads cleanly without deadlocking.
	{
		NoServe_Result :: struct {
			allocator:      runtime.Allocator,
			setup_err:      http.Server_Error,
			socket_cleared: bool,
			threads_nil:    bool,
			loop_nil:       bool,
		}
		res := NoServe_Result{allocator = context.allocator}

		worker := thread.create_and_start_with_data(&res, proc(data: rawptr) {
			res := (^NoServe_Result)(data)
			context.allocator = res.allocator
			s := http.make_server(http.Server_Options{
				address      = nbio.IP4_Loopback,
				port         = 18097,
				thread_count = 2,
			})
			res.setup_err = http._setup(&s)
			http._destroy(&s)
			res.socket_cleared = s.socket == {}
			res.threads_nil    = s.threads == nil
			res.loop_nil       = nbio.current_thread_event_loop() == nil
		})
		testing.expect(t, worker != nil, "expected helper thread created")
		thread.destroy(worker)

		testing.expect_value(t, res.setup_err, nil)
		testing.expect(t, res.socket_cleared, "expected s.socket closed and cleared by _destroy")
		testing.expect(t, res.threads_nil, "expected s.threads cleaned up and nil after _destroy")
		testing.expect(t, res.loop_nil, "expected event loop released cleanly")
	}
}

@(test)
test_http2_streaming_body_bounded_memory :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	UPLOAD_SIZE :: 2 * mem.Megabyte
	PARSED_SIZE :: 128 * mem.Kilobyte
	CHUNK_SIZE  :: 16 * mem.Kilobyte

	fnv1a_step :: proc(h: u64, data: []byte) -> u64 {
		res := h
		for b in data {
			res = (res ~ u64(b)) * 1099511628211
		}
		return res
	}

	expected_hash_for :: proc(total: int) -> u64 {
		h: u64 = 14695981039346656037
		buf: [16 * 1024]byte
		pos := 0
		for pos < total {
			n := min(len(buf), total - pos)
			for i in 0..<n {
				buf[i] = u8(((pos + i) * 31 + 7) & 0xFF)
			}
			h = fnv1a_step(h, buf[:n])
			pos += n
		}
		return h
	}

	Stream_State :: struct {
		count:        int,
		hash:         u64,
		track:        ^mem.Tracking_Allocator,
		peak_out:     ^i64,
		sentinel:     []byte,
	}

	Server_Check :: struct {
		track:                  ^mem.Tracking_Allocator,
		peak_after_cl:          i64,
		peak_after_chunked:     i64,
		cl_temp_ok:             bool,
		chunked_temp_ok:        bool,
	}

	server_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&server_track, context.allocator)
	server_track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&server_track)

	srv_check := Server_Check{track = &server_track}

	r: http.Router
	defer http.router_destroy(r)

	http.route_post(&r, "/stream-cl", http.Handler{
		user_data = &srv_check,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			chk := (^Server_Check)(h.user_data)
			sentinel, serr := make([]byte, 128, context.temp_allocator)
			if serr != nil {
				ctx.res.status = .Internal_Server_Error
				http.respond(&ctx.res)
				return
			}
			for &b in sentinel { b = 0x5A }

			http.context_add(ctx, Stream_State{
				hash     = 14695981039346656037,
				track    = chk.track,
				peak_out = &chk.peak_after_cl,
				sentinel = sentinel,
			})
			http.context_add(ctx, chk)

			http.body(&ctx.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {
				ctx := http.context_of_request(req)
				st  := http.context_get(ctx, Stream_State)
				for b in body {
					st.hash = (st.hash ~ u64(b)) * 1099511628211
				}
				st.count += len(body)

				if !is_partial {
					chk := http.context_get(ctx, ^Server_Check)^
					st.peak_out^ = st.track.peak_memory_allocated
					temp_ok := len(st.sentinel) == 128 && sanitizer.address_region_is_poisoned(st.sentinel) == nil
					for b in st.sentinel {
						if b != 0x5A { temp_ok = false }
					}
					chk.cl_temp_ok = temp_ok
					tag, _ := http.get_header(req, "X-Request-Tag")
					http.set_header(&ctx.res, "connection", "close")
					http.respond_plain(&ctx.res, fmt.aprintf("%d:%d:%s", st.count, st.hash, tag, allocator = http.transaction_allocator(ctx)))
				}
			})
		},
	})

	http.route_post(&r, "/stream-chunked", http.Handler{
		user_data = &srv_check,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			chk := (^Server_Check)(h.user_data)
			sentinel, serr := make([]byte, 128, context.temp_allocator)
			if serr != nil {
				ctx.res.status = .Internal_Server_Error
				http.respond(&ctx.res)
				return
			}
			for &b in sentinel { b = 0xA5 }

			http.context_add(ctx, Stream_State{
				hash     = 14695981039346656037,
				track    = chk.track,
				peak_out = &chk.peak_after_chunked,
				sentinel = sentinel,
			})
			http.context_add(ctx, chk)

			http.body(&ctx.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {
				ctx := http.context_of_request(req)
				st  := http.context_get(ctx, Stream_State)
				for b in body {
					st.hash = (st.hash ~ u64(b)) * 1099511628211
				}
				st.count += len(body)

				if !is_partial {
					chk := http.context_get(ctx, ^Server_Check)^
					st.peak_out^ = st.track.peak_memory_allocated
					temp_ok := len(st.sentinel) == 128 && sanitizer.address_region_is_poisoned(st.sentinel) == nil
					for b in st.sentinel {
						if b != 0xA5 { temp_ok = false }
					}
					chk.chunked_temp_ok = temp_ok
					tag, _ := http.get_header(req, "X-Request-Tag")
					tr, _  := http.get_header(req, "X-Trailer-Check")
					http.set_header(&ctx.res, "connection", "close")
					http.respond_plain(&ctx.res, fmt.aprintf("%d:%d:%s:%s", st.count, st.hash, tag, tr, allocator = http.transaction_allocator(ctx)))
				}
			})
		},
	})

	parsed_next := http.handler(proc(ctx: ^http.Ctx) {
		bps: http.Body_Parser_Stream
		http.body_parser_stream_init(&bps, ctx)
		stream := http.body_parser_stream(&bps)

		h: u64 = 14695981039346656037
		total := 0
		buf: [4096]byte
		for {
			n, rerr := io.read(stream, buf[:])
			if n > 0 {
				for b in buf[:n] {
					h = (h ~ u64(b)) * 1099511628211
				}
				total += n
			}
			if rerr == .EOF {
				break
			}
			if rerr != nil {
				ctx.res.status = .Internal_Server_Error
				http.respond(&ctx.res)
				return
			}
		}
		http.set_header(&ctx.res, "connection", "close")
		http.respond_plain(&ctx.res, fmt.aprintf("%d:%d", total, h, allocator = http.transaction_allocator(ctx)))
	})
	parsed_handler := http.body_parser(&parsed_next)
	http.route_post(&r, "/parsed", parsed_handler)

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18098,
		thread_count = 1,
		body_quota   = {max_size = 4 * mem.Megabyte, min = 5 * time.Second},
		handler      = http.router(&r),
	}, mem.tracking_allocator(&server_track))

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	Client_Result :: struct {
		server:       ^http.Server,
		endpoint_err: net.Socket_Info_Error,
		cl_ok:        bool,
		chunked_ok:   bool,
		parsed_ok:    bool,
		cl_body:      [256]byte,
		cl_len:       int,
		chunked_body: [256]byte,
		chunked_len:  int,
		parsed_body:  [256]byte,
		parsed_len:   int,
	}
	res := Client_Result{server = &server}

	client_thread := thread.create_and_start_with_data(&res, proc(data: rawptr) {
		res := (^Client_Result)(data)
		defer http.server_shutdown(res.server)

		endpoint, ep_err := nbio.bound_endpoint(res.server.socket)
		res.endpoint_err = ep_err
		if ep_err != nil {
			return
		}

		send_all :: proc(sock: net.TCP_Socket, bytes: []byte) -> bool {
			sent := 0
			for sent < len(bytes) {
				n, serr := net.send_tcp(sock, bytes[sent:])
				if serr != nil || n <= 0 {
					return false
				}
				sent += n
			}
			return true
		}

		recv_body :: proc(sock: net.TCP_Socket, out_body: []byte) -> (n: int, ok: bool) {
			resp_buf: [2048]byte
			total := 0
			for total < len(resp_buf) {
				rn, rerr := net.recv_tcp(sock, resp_buf[total:])
				if rn > 0 {
					total += rn
				}
				if rn == 0 || rerr != nil {
					break
				}
			}
			sep := strings.index(string(resp_buf[:total]), "\r\n\r\n")
			if sep < 0 {
				return 0, false
			}
			if !strings.has_prefix(string(resp_buf[:total]), "HTTP/1.1 200 ") {
				return 0, false
			}
			body := resp_buf[sep+4:total]
			return copy(out_body, body), len(body) <= len(out_body)
		}

		write_pattern :: proc(buf: []byte, start_pos: int) {
			for i in 0..<len(buf) {
				buf[i] = u8(((start_pos + i) * 31 + 7) & 0xFF)
			}
		}

		WRITE_SIZE :: 64 * mem.Kilobyte
		payload: [WRITE_SIZE]byte
		hdr_buf: [512]byte

		// 1. 2 MiB Content-Length upload (64 KiB TCP writes to exercise adaptive .Reuse ramp-up).
		if sock, derr := net.dial_tcp(endpoint); derr == nil {
			defer net.close(sock)
			hdr := fmt.bprintf(
				hdr_buf[:],
				"POST /stream-cl HTTP/1.1\r\nHost: localhost\r\nX-Request-Tag: keep-me\r\nContent-Length: %d\r\n\r\n",
				UPLOAD_SIZE,
			)
			ok := send_all(sock, transmute([]byte)hdr)
			pos := 0
			for ok && pos < UPLOAD_SIZE {
				n := min(len(payload), UPLOAD_SIZE - pos)
				write_pattern(payload[:n], pos)
				ok = send_all(sock, payload[:n])
				pos += n
			}
			if ok {
				bn, bok := recv_body(sock, res.cl_body[:])
				res.cl_len = bn
				res.cl_ok  = bok
			}
		}

		// 2. 2 MiB Transfer-Encoding: chunked upload with trailer.
		if sock, derr := net.dial_tcp(endpoint); derr == nil {
			defer net.close(sock)
			hdr := "POST /stream-chunked HTTP/1.1\r\nHost: localhost\r\nX-Request-Tag: keep-me\r\nTransfer-Encoding: chunked\r\nTrailer: X-Trailer-Check\r\n\r\n"
			ok := send_all(sock, transmute([]byte)hdr)
			pos := 0
			for ok && pos < UPLOAD_SIZE {
				n := min(CHUNK_SIZE, UPLOAD_SIZE - pos)
				chunk_hdr := fmt.bprintf(hdr_buf[:], "%x\r\n", n)
				write_pattern(payload[:n], pos)
				ok = send_all(sock, transmute([]byte)chunk_hdr) &&
					send_all(sock, payload[:n]) &&
					send_all(sock, transmute([]byte)string("\r\n"))
				pos += n
			}
			if ok {
				ok = send_all(sock, transmute([]byte)string("0\r\nX-Trailer-Check: ok-trailer\r\n\r\n"))
			}
			if ok {
				bn, bok := recv_body(sock, res.chunked_body[:])
				res.chunked_len = bn
				res.chunked_ok  = bok
			}
		}

		// 3. 128 KiB body_parser upload across multiple writes.
		if sock, derr := net.dial_tcp(endpoint); derr == nil {
			defer net.close(sock)
			hdr := fmt.bprintf(
				hdr_buf[:],
				"POST /parsed HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n",
				PARSED_SIZE,
			)
			ok := send_all(sock, transmute([]byte)hdr)
			pos := 0
			for ok && pos < PARSED_SIZE {
				n := min(4096, PARSED_SIZE - pos)
				write_pattern(payload[:n], pos)
				ok = send_all(sock, payload[:n])
				pos += n
			}
			if ok {
				bn, bok := recv_body(sock, res.parsed_body[:])
				res.parsed_len = bn
				res.parsed_ok  = bok
			}
		}
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	expected_2m  := expected_hash_for(UPLOAD_SIZE)
	expected_128 := expected_hash_for(PARSED_SIZE)
	exp_cl_str      := fmt.tprintf("%d:%d:keep-me", UPLOAD_SIZE, expected_2m)
	exp_chunked_str := fmt.tprintf("%d:%d:keep-me:ok-trailer", UPLOAD_SIZE, expected_2m)
	exp_parsed_str  := fmt.tprintf("%d:%d", PARSED_SIZE, expected_128)

	testing.expect_value(t, res.endpoint_err, nil)
	testing.expect(t, res.cl_ok, "expected 2 MiB Content-Length streaming upload to succeed")
	testing.expect_value(t, string(res.cl_body[:res.cl_len]), exp_cl_str)
	testing.expect(t, res.chunked_ok, "expected 2 MiB chunked streaming upload to succeed")
	testing.expect_value(t, string(res.chunked_body[:res.chunked_len]), exp_chunked_str)
	testing.expect(t, res.parsed_ok, "expected 128 KiB body_parser upload to succeed")
	testing.expect_value(t, string(res.parsed_body[:res.parsed_len]), exp_parsed_str)

	testing.expect(t, srv_check.cl_temp_ok, "expected temp_allocator data preserved during Content-Length streaming")
	testing.expect(t, srv_check.chunked_temp_ok, "expected temp_allocator data preserved during chunked streaming")
	testing.expect(t, srv_check.peak_after_cl > 0 && srv_check.peak_after_cl < 768 * mem.Kilobyte, "expected O(1) bounded peak memory during 2 MiB Content-Length streaming")
	testing.expect(t, srv_check.peak_after_chunked > 0 && srv_check.peak_after_chunked < 768 * mem.Kilobyte, "expected O(1) bounded peak memory during 2 MiB chunked streaming")
	testing.expect(t, server_track.peak_memory_allocated < 768 * mem.Kilobyte, "expected bounded peak memory after 128 KiB body_parser upload")

	testing.expect_value(t, server_track.current_memory_allocated, 0)
	testing.expect_value(t, len(server_track.bad_free_array), 0)
}

@(test)
test_http2_streaming_response_bounded_memory :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	STREAM_SIZE :: 2 * mem.Megabyte
	CHUNK_SIZE  :: 4 * mem.Kilobyte
	BURST_CHUNKS :: 4
	BURST_CHUNK_SIZE :: 1024

	fnv1a_step :: proc(h: u64, data: []byte) -> u64 {
		res := h
		for b in data {
			res = (res ~ u64(b)) * 1099511628211
		}
		return res
	}

	write_pattern :: proc(buf: []byte, start_pos: int) {
		for i in 0..<len(buf) {
			buf[i] = u8(((start_pos + i) * 31 + 7) & 0xFF)
		}
	}

	expected_hash_for :: proc(total: int) -> u64 {
		h: u64 = 14695981039346656037
		buf: [16 * 1024]byte
		pos := 0
		for pos < total {
			n := min(len(buf), total - pos)
			write_pattern(buf[:n], pos)
			h = fnv1a_step(h, buf[:n])
			pos += n
		}
		return h
	}

	server_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&server_track, context.allocator)
	server_track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&server_track)

	Server_Peak_Check :: struct {
		track:                ^mem.Tracking_Allocator,
		peak_seq:             i64,
		peak_burst:           i64,
		seq_zero_tx_growth:   bool,
		burst_zero_tx_growth: bool,
		burst_saw_multi:      bool,
	}
	srv_check := Server_Peak_Check{track = &server_track}

	r: http.Router
	defer http.router_destroy(r)

	// 1. Sequential send_chunk streaming (depth=1, reusing one 4 KiB buffer and inline_hdr).
	Seq_State :: struct {
		buf:            [CHUNK_SIZE]byte,
		pos:            int,
		chunks:         int,
		tx_tail_1:      rawptr,
		tx_offset_1:    int,
		chk:            ^Server_Peak_Check,
	}
	http.route_get(&r, "/seq", http.Handler{
		user_data = &srv_check,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			chk := (^Server_Peak_Check)(h.user_data)
			if _, err := http.context_add(ctx, Seq_State{chk = chk}); err != nil {
				ctx.res.status = .Internal_Server_Error
				http.respond(&ctx.res)
				return
			}

			send_next :: proc(c: ^http.Connection, err: http.Send_Error) {
				if err != nil || c.res._state == .Error {
					return
				}
				st := http.context_get(&c.ctx, Seq_State)
				if st.pos >= STREAM_SIZE {
					st.chk.peak_seq = st.chk.track.peak_memory_allocated
					st.chk.seq_zero_tx_growth =
						st.tx_tail_1 != nil &&
						rawptr(c.transaction_arena.tail) == st.tx_tail_1 &&
						c.transaction_arena.tail.offset == st.tx_offset_1
					http.respond(&c.res)
					return
				}
				n := min(len(st.buf), STREAM_SIZE - st.pos)
				for i in 0..<n {
					st.buf[i] = u8(((st.pos + i) * 31 + 7) & 0xFF)
				}
				st.pos    += n
				st.chunks += 1
				http.send_chunk(&c.res, {st.buf[:n]}, send_next)
				if st.chunks == 1 && c.transaction_arena.tail != nil {
					st.tx_tail_1   = c.transaction_arena.tail
					st.tx_offset_1 = c.transaction_arena.tail.offset
				}
			}

			send_next(http.connection_of_context(ctx), nil)
		},
	})

	// 2. Bursty send_chunk streaming (4 x 1 KiB chunks per burst, draining to _sends == 0 between bursts).
	Burst_State :: struct {
		bufs:        [BURST_CHUNKS][BURST_CHUNK_SIZE]byte,
		pos:         int,
		bursts:      int,
		tx_tail_1:   rawptr,
		tx_offset_1: int,
		chk:         ^Server_Peak_Check,
	}
	http.route_get(&r, "/burst", http.Handler{
		user_data = &srv_check,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			chk := (^Server_Peak_Check)(h.user_data)
			if _, err := http.context_add(ctx, Burst_State{chk = chk}); err != nil {
				ctx.res.status = .Internal_Server_Error
				http.respond(&ctx.res)
				return
			}

			send_burst :: proc(c: ^http.Connection) {
				if c.res._state == .Error {
					return
				}
				st := http.context_get(&c.ctx, Burst_State)
				if st.pos >= STREAM_SIZE {
					st.chk.peak_burst = st.chk.track.peak_memory_allocated
					st.chk.burst_zero_tx_growth =
						st.tx_tail_1 != nil &&
						rawptr(c.transaction_arena.tail) == st.tx_tail_1 &&
						c.transaction_arena.tail.offset == st.tx_offset_1
					http.respond(&c.res)
					return
				}

				st.bursts += 1
				for i in 0..<BURST_CHUNKS {
					if st.pos >= STREAM_SIZE {
						break
					}
					n := min(len(st.bufs[i]), STREAM_SIZE - st.pos)
					for j in 0..<n {
						st.bufs[i][j] = u8(((st.pos + j) * 31 + 7) & 0xFF)
					}
					st.pos += n
					if c.res._sends > 0 {
						st.chk.burst_saw_multi = true
					}
					http.send_chunk(&c.res, {st.bufs[i][:n]}, on_burst_part)
				}
				if st.bursts == 1 && c.transaction_arena.tail != nil {
					st.tx_tail_1   = c.transaction_arena.tail
					st.tx_offset_1 = c.transaction_arena.tail.offset
				}
			}

			on_burst_part :: proc(c: ^http.Connection, err: http.Send_Error) {
				if err != nil || c.res._state == .Error || c.res._sends > 0 {
					return
				}
				send_burst(c)
			}

			send_burst(http.connection_of_context(ctx))
		},
	})

	http.route_get(&r, "/after", proc(ctx: ^http.Ctx) {
		http.respond_plain(&ctx.res, "still-alive")
	})

	server := http.make_server(http.Server_Options{
		address        = nbio.IP4_Loopback,
		port           = 18099,
		thread_count   = 1,
		response_quota = http.UNLIMITED_QUOTA,
		handler        = http.router(&r),
	}, mem.tracking_allocator(&server_track))

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	Hash_Result :: struct {
		setopt_ok:   bool,
		perform_err: curl.code,
		getinfo_err: curl.code,
		status:      c.long,
		count:       int,
		hash:        u64,
		small_buf:   [64]byte,
		small_len:   int,
	}

	Client_Result :: struct {
		server:       ^http.Server,
		endpoint_err: net.Socket_Info_Error,
		handle_ok:    bool,
		seq:          Hash_Result,
		burst:        Hash_Result,
		after:        Hash_Result,
	}
	res := Client_Result{server = &server}

	client_thread := thread.create_and_start_with_data(&res, proc(data: rawptr) {
		res := (^Client_Result)(data)
		defer http.server_shutdown(res.server)

		endpoint, ep_err := nbio.bound_endpoint(res.server.socket)
		res.endpoint_err = ep_err
		if ep_err != nil {
			return
		}

		handle := curl.easy_init()
		res.handle_ok = handle != nil
		if handle == nil {
			return
		}
		defer curl.easy_cleanup(handle)

		write_hash :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
			r := (^Hash_Result)(userp)
			n := int(size) * int(nmemb)
			for i in 0..<n {
				r.hash = (r.hash ~ u64(contents[i])) * 1099511628211
			}
			if r.count < len(r.small_buf) {
				copied := copy(r.small_buf[r.small_len:], contents[:min(n, len(r.small_buf) - r.small_len)])
				r.small_len += copied
			}
			r.count += n
			return c.size_t(n)
		}

		do_req :: proc(handle: ^curl.CURL, port: int, path: string, out: ^Hash_Result) {
			out.hash = 14695981039346656037
			url := fmt.ctprintf("http://127.0.0.1:%d%s", port, path)
			out.setopt_ok =
				curl.easy_setopt(handle, .HTTPGET, c.long(1)) == .E_OK &&
				curl.easy_setopt(handle, .URL, url) == .E_OK &&
				curl.easy_setopt(handle, .WRITEFUNCTION, write_hash) == .E_OK &&
				curl.easy_setopt(handle, .WRITEDATA, out) == .E_OK
			if !out.setopt_ok {
				return
			}
			out.perform_err = curl.easy_perform(handle)
			out.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &out.status)
		}

		do_req(handle, endpoint.port, "/seq",   &res.seq)
		do_req(handle, endpoint.port, "/burst", &res.burst)
		do_req(handle, endpoint.port, "/after", &res.after)
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	testing.expect_value(t, res.endpoint_err, nil)
	testing.expect(t, res.handle_ok, "curl.easy_init failed")

	expected_hash := expected_hash_for(STREAM_SIZE)

	check_stream :: proc(t: ^testing.T, name: string, got: ^Hash_Result, exp_len: int, exp_hash: u64) {
		testing.expectf(t, got.setopt_ok, "%s: setopt failed", name)
		testing.expectf(t, got.perform_err == .E_OK, "%s: curl failed: %s", name, curl.easy_strerror(got.perform_err))
		testing.expect_value(t, got.getinfo_err, curl.code.E_OK)
		testing.expect_value(t, got.status, c.long(200))
		testing.expect_value(t, got.count, exp_len)
		testing.expect_value(t, got.hash, exp_hash)
	}

	check_stream(t, "seq",   &res.seq,   STREAM_SIZE, expected_hash)
	check_stream(t, "burst", &res.burst, STREAM_SIZE, expected_hash)

	testing.expect_value(t, res.after.perform_err, curl.code.E_OK)
	testing.expect_value(t, res.after.status, c.long(200))
	testing.expect_value(t, string(res.after.small_buf[:res.after.small_len]), "still-alive")

	testing.expect(t, srv_check.seq_zero_tx_growth, "expected zero transaction_arena growth after first sequential chunk")
	testing.expect(t, srv_check.burst_saw_multi, "expected bursty send_chunk to have overlapping sends in flight")
	testing.expect(t, srv_check.burst_zero_tx_growth, "expected zero transaction_arena growth after first drained burst")
	testing.expect(t, srv_check.peak_seq > 0 && srv_check.peak_seq < 256 * mem.Kilobyte, "expected O(1) bounded peak memory during 2 MiB sequential send_chunk")
	testing.expect(t, srv_check.peak_burst > 0 && srv_check.peak_burst < 256 * mem.Kilobyte, "expected O(max_burst) bounded peak memory during 2 MiB bursty send_chunk")
	testing.expect(t, server_track.peak_memory_allocated < 256 * mem.Kilobyte, "expected O(1) bounded overall server peak memory across all 2 MiB streams")

	testing.expect_value(t, server_track.current_memory_allocated, 0)
	testing.expect_value(t, len(server_track.bad_free_array), 0)
}

@(test)
test_http2_streaming_body_backpressure_zero_copy :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	STREAM_SIZE :: 2 * mem.Megabyte

	fnv1a_step :: proc(h: u64, data: []byte) -> u64 {
		h := h
		for b in data {
			h = (h ~ u64(b)) * 1099511628211
		}
		return h
	}

	expected_hash_for :: proc(total: int) -> u64 {
		h: u64 = 14695981039346656037
		buf: [16 * 1024]byte
		pos := 0
		for pos < total {
			n := min(len(buf), total - pos)
			for i in 0..<n {
				buf[i] = u8(((pos + i) * 31 + 7) & 0xFF)
			}
			h = fnv1a_step(h, buf[:n])
			pos += n
		}
		return h
	}

	server_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&server_track, context.allocator)
	server_track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&server_track)

	Echo_Stats :: struct {
		track:             ^mem.Tracking_Allocator,
		cl_pauses:         int,
		chunked_pauses:    int,
		cl_steady_chunks:  int,
		chunked_steady:    int,
		cl_unexpected_alloc:      bool,
		chunked_unexpected_alloc: bool,
	}
	stats := Echo_Stats{track = &server_track}

	Echo_Kind :: enum {
		Content_Length,
		Chunked,
	}
	Echo_Req :: struct {
		stats:      ^Echo_Stats,
		kind:       Echo_Kind,
		chunks:     int,
		prev_buf:   int,
		prev_alloc: i64,
	}

	handle_echo :: proc(ctx: ^http.Ctx, stats: ^Echo_Stats, kind: Echo_Kind) {
		if _, err := http.context_add(ctx, Echo_Req{stats = stats, kind = kind}); err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(&ctx.res)
			return
		}

		on_echo_sent :: proc(c: ^http.Connection, err: http.Send_Error) {
			if err != nil || c.res._state == .Error {
				return
			}
			http.body_resume(&c.req)
		}

		http.body(&ctx.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {
			c := http.connection_of_request(req)
			er := http.context_get(&c.ctx, Echo_Req)
			st := er.stats

			if !is_partial {
				if er.chunks >= 2 && st.track.total_memory_allocated != er.prev_alloc {
					switch er.kind {
					case .Content_Length: st.cl_unexpected_alloc = true
					case .Chunked:        st.chunked_unexpected_alloc = true
					}
				}
				http.respond(&c.res)
				return
			}

			er.chunks += 1
			cur_buf   := len(c.scanner.buf)
			cur_alloc := st.track.total_memory_allocated
			if er.chunks >= 2 && cur_buf == er.prev_buf {
				if cur_alloc != er.prev_alloc {
					switch er.kind {
					case .Content_Length: st.cl_unexpected_alloc = true
					case .Chunked:        st.chunked_unexpected_alloc = true
					}
				}
				switch er.kind {
				case .Content_Length: st.cl_steady_chunks += 1
				case .Chunked:        st.chunked_steady += 1
				}
			}
			er.prev_buf = cur_buf

			http.body_pause(req)
			switch er.kind {
			case .Content_Length: st.cl_pauses += 1
			case .Chunked:        st.chunked_pauses += 1
			}
			// Zero-copy pass of `retain = false` scanner slice directly into async `send_chunk`.
			http.send_chunk(&c.res, {body}, on_echo_sent)
			er.prev_alloc = st.track.total_memory_allocated
		}, retain = false)
	}

	r: http.Router
	defer http.router_destroy(r)

	http.route_post(&r, "/echo-cl", http.Handler{
		user_data = &stats,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			handle_echo(ctx, (^Echo_Stats)(h.user_data), .Content_Length)
		},
	})
	http.route_post(&r, "/echo-chunked", http.Handler{
		user_data = &stats,
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			handle_echo(ctx, (^Echo_Stats)(h.user_data), .Chunked)
		},
	})
	http.route_get(&r, "/after", proc(ctx: ^http.Ctx) {
		http.respond_plain(&ctx.res, "still-alive")
	})

	server := http.make_server(http.Server_Options{
		address        = nbio.IP4_Loopback,
		port           = 18100,
		thread_count   = 1,
		body_quota     = http.UNLIMITED_QUOTA,
		response_quota = http.UNLIMITED_QUOTA,
		handler        = http.router(&r),
	}, mem.tracking_allocator(&server_track))

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	Hash_Result :: struct {
		setopt_ok:   bool,
		perform_err: curl.code,
		getinfo_err: curl.code,
		status:      c.long,
		count:       int,
		hash:        u64,
		small_buf:   [64]byte,
		small_len:   int,
	}

	Upload_State :: struct {
		sent:  int,
		total: int,
	}

	Client_Result :: struct {
		server:       ^http.Server,
		endpoint_err: net.Socket_Info_Error,
		handle_ok:    bool,
		cl:           Hash_Result,
		chunked:      Hash_Result,
		after:        Hash_Result,
	}
	res := Client_Result{server = &server}

	client_thread := thread.create_and_start_with_data(&res, proc(data: rawptr) {
		res := (^Client_Result)(data)
		defer http.server_shutdown(res.server)

		endpoint, ep_err := nbio.bound_endpoint(res.server.socket)
		res.endpoint_err = ep_err
		if ep_err != nil {
			return
		}

		handle := curl.easy_init()
		res.handle_ok = handle != nil
		if handle == nil {
			return
		}
		defer curl.easy_cleanup(handle)

		read_pattern :: proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
			st := (^Upload_State)(userdata)
			if st.sent >= st.total {
				return 0
			}
			max_n := min(int(size) * int(nmemb), 16 * 1024)
			n := min(max_n, st.total - st.sent)
			for i in 0..<n {
				ptr[i] = u8(((st.sent + i) * 31 + 7) & 0xFF)
			}
			st.sent += n
			return c.size_t(n)
		}

		write_hash :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
			r := (^Hash_Result)(userp)
			n := int(size) * int(nmemb)
			for i in 0..<n {
				r.hash = (r.hash ~ u64(contents[i])) * 1099511628211
			}
			if r.count < len(r.small_buf) {
				copied := copy(r.small_buf[r.small_len:], contents[:min(n, len(r.small_buf) - r.small_len)])
				r.small_len += copied
			}
			r.count += n
			return c.size_t(n)
		}

		// 1. POST /echo-cl with Content-Length: 2 MiB.
		{
			up := Upload_State{total = STREAM_SIZE}
			res.cl.hash = 14695981039346656037
			hdrs := curl.slist_append(nil, "Expect:")
			defer curl.slist_free_all(hdrs)
			url := fmt.ctprintf("http://127.0.0.1:%d/echo-cl", endpoint.port)
			res.cl.setopt_ok =
				curl.easy_setopt(handle, .URL, url) == .E_OK &&
				curl.easy_setopt(handle, .POST, c.long(1)) == .E_OK &&
				curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(STREAM_SIZE)) == .E_OK &&
				curl.easy_setopt(handle, .HTTPHEADER, hdrs) == .E_OK &&
				curl.easy_setopt(handle, .READFUNCTION, read_pattern) == .E_OK &&
				curl.easy_setopt(handle, .READDATA, &up) == .E_OK &&
				curl.easy_setopt(handle, .WRITEFUNCTION, write_hash) == .E_OK &&
				curl.easy_setopt(handle, .WRITEDATA, &res.cl) == .E_OK
			if res.cl.setopt_ok {
				res.cl.perform_err = curl.easy_perform(handle)
				res.cl.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.cl.status)
			}
		}

		// 2. POST /echo-chunked with Transfer-Encoding: chunked (2 MiB).
		{
			up := Upload_State{total = STREAM_SIZE}
			res.chunked.hash = 14695981039346656037
			hdrs := curl.slist_append(nil, "Transfer-Encoding: chunked")
			hdrs = curl.slist_append(hdrs, "Expect:")
			defer curl.slist_free_all(hdrs)
			url := fmt.ctprintf("http://127.0.0.1:%d/echo-chunked", endpoint.port)
			res.chunked.setopt_ok =
				curl.easy_setopt(handle, .URL, url) == .E_OK &&
				curl.easy_setopt(handle, .POST, c.long(1)) == .E_OK &&
				curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(-1)) == .E_OK &&
				curl.easy_setopt(handle, .HTTPHEADER, hdrs) == .E_OK &&
				curl.easy_setopt(handle, .READFUNCTION, read_pattern) == .E_OK &&
				curl.easy_setopt(handle, .READDATA, &up) == .E_OK &&
				curl.easy_setopt(handle, .WRITEFUNCTION, write_hash) == .E_OK &&
				curl.easy_setopt(handle, .WRITEDATA, &res.chunked) == .E_OK
			if res.chunked.setopt_ok {
				res.chunked.perform_err = curl.easy_perform(handle)
				res.chunked.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.chunked.status)
			}
		}

		// 3. GET /after verifying server stays healthy.
		{
			res.after.hash = 14695981039346656037
			url := fmt.ctprintf("http://127.0.0.1:%d/after", endpoint.port)
			res.after.setopt_ok =
				curl.easy_setopt(handle, .URL, url) == .E_OK &&
				curl.easy_setopt(handle, .POST, c.long(0)) == .E_OK &&
				curl.easy_setopt(handle, .HTTPGET, c.long(1)) == .E_OK &&
				curl.easy_setopt(handle, .HTTPHEADER, nil) == .E_OK &&
				curl.easy_setopt(handle, .READFUNCTION, nil) == .E_OK &&
				curl.easy_setopt(handle, .READDATA, nil) == .E_OK &&
				curl.easy_setopt(handle, .WRITEFUNCTION, write_hash) == .E_OK &&
				curl.easy_setopt(handle, .WRITEDATA, &res.after) == .E_OK
			if res.after.setopt_ok {
				res.after.perform_err = curl.easy_perform(handle)
				res.after.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.after.status)
			}
		}
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	testing.expect_value(t, res.endpoint_err, nil)
	testing.expect(t, res.handle_ok, "curl.easy_init failed")

	expected_hash := expected_hash_for(STREAM_SIZE)

	check_stream :: proc(t: ^testing.T, name: string, got: ^Hash_Result, exp_len: int, exp_hash: u64) {
		testing.expectf(t, got.setopt_ok, "%s: setopt failed", name)
		testing.expectf(t, got.perform_err == .E_OK, "%s: curl failed: %s", name, curl.easy_strerror(got.perform_err))
		testing.expect_value(t, got.getinfo_err, curl.code.E_OK)
		testing.expect_value(t, got.status, c.long(200))
		testing.expect_value(t, got.count, exp_len)
		testing.expect_value(t, got.hash, exp_hash)
	}

	check_stream(t, "echo-cl",      &res.cl,      STREAM_SIZE, expected_hash)
	check_stream(t, "echo-chunked", &res.chunked, STREAM_SIZE, expected_hash)

	testing.expect(t, res.after.setopt_ok, "after: setopt failed")
	testing.expectf(t, res.after.perform_err == .E_OK, "after: curl failed: %s", curl.easy_strerror(res.after.perform_err))
	testing.expect_value(t, res.after.status, c.long(200))
	testing.expect_value(t, string(res.after.small_buf[:res.after.small_len]), "still-alive")

	testing.expect(t, stats.cl_pauses > 10, "expected Content-Length echo to pause across many chunks")
	testing.expect(t, stats.chunked_pauses > 10, "expected chunked echo to pause across many chunks")
	testing.expect(t, stats.cl_steady_chunks > 10 && !stats.cl_unexpected_alloc, "expected zero per-chunk allocations during paused Content-Length echo")
	testing.expect(t, stats.chunked_steady > 10 && !stats.chunked_unexpected_alloc, "expected zero per-chunk allocations during paused chunked echo")
	testing.expect(t, server_track.peak_memory_allocated < 768 * mem.Kilobyte, "expected O(1) bounded peak server memory across 2 MiB paused zero-copy echoes")

	testing.expect_value(t, server_track.current_memory_allocated, 0)
	testing.expect_value(t, len(server_track.bad_free_array), 0)
}
