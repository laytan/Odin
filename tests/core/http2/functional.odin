#+build windows, linux, darwin
package tests_http2

import "base:runtime"

import c "core:c/libc"
import "core:container/xar"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:mem/virtual"
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
		shutdown_timeout     = 200 * time.Millisecond,
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

	// 3. Stalled active connection keeps shutdown waiting until shutdown_timeout expires, without hanging.
	shutdown_elapsed := time.diff(ctx.shutdown_started_at, serve_finished_at)
	testing.expect(t, shutdown_elapsed >= 150 * time.Millisecond, "expected shutdown to wait for shutdown_timeout on stalled active connection")
	testing.expect(t, shutdown_elapsed < 2 * time.Second, "expected shutdown not to hang past shutdown_timeout")

	// 4. Both idle and stalled connections were closed by the server.
	eof_buf: [16]byte
	idle_n, idle_recv_err := net.recv_tcp(ctx.idle_sock, eof_buf[:])
	testing.expect(t, idle_n == 0 || idle_recv_err != nil, "expected idle socket to be closed by server shutdown")
	stalled_n, stalled_recv_err := net.recv_tcp(ctx.stalled_sock, eof_buf[:])
	testing.expect(t, stalled_n == 0 || stalled_recv_err != nil, "expected stalled socket to be closed after shutdown_timeout")

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
	http.route_get(&r, "/writer", proc(ctx: ^http.Ctx) {
		http.set_header(&ctx.res, "Content-Type", "application/x-ndjson")
		cw: http.Chunked_Writer
		w := http.chunked_writer_init(&cw, &ctx.res, chunk_size = 8)
		defer io.close(w)

		fmt.wprintln(w, "line1")
		io.flush(w)
		opt: json.Marshal_Options
		json.marshal_to_writer(w, Json_Payload{msg = "stream", count = 7}, &opt)
	})
	http.route_get(&r, "/writer-unbuffered", proc(ctx: ^http.Ctx) {
		cw: http.Chunked_Writer
		w := http.chunked_writer_init(&cw, &ctx.res, chunk_size = 0)
		defer io.close(w)

		io.write_string(w, "alpha-")
		io.write_string(w, "beta")
	})
	http.route_get(&r, "/writer-empty", proc(ctx: ^http.Ctx) {
		cw: http.Chunked_Writer
		w := http.chunked_writer_init(&cw, &ctx.res)
		io.close(w)
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
		server:            ^http.Server,
		endpoint_err:      net.Socket_Info_Error,
		handle_ok:         bool,
		plain:             File_Case_Result,
		html:              File_Case_Result,
		json_get:          File_Case_Result,
		json_head:         File_Case_Result,
		json_err:          File_Case_Result,
		chunks:            File_Case_Result,
		writer:            File_Case_Result,
		writer_unbuffered: File_Case_Result,
		writer_empty:      File_Case_Result,
		writer_head:       File_Case_Result,
		after_keepalive:   File_Case_Result,
	}

	ctx := Respond_Helpers_Context{server = &server}
	defer delete(ctx.plain.response.body)
	defer delete(ctx.html.response.body)
	defer delete(ctx.json_get.response.body)
	defer delete(ctx.json_head.response.body)
	defer delete(ctx.json_err.response.body)
	defer delete(ctx.chunks.response.body)
	defer delete(ctx.writer.response.body)
	defer delete(ctx.writer_unbuffered.response.body)
	defer delete(ctx.writer_empty.response.body)
	defer delete(ctx.writer_head.response.body)
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

		do_req(handle, endpoint.port, "/plain",             false, &ctx.plain)
		do_req(handle, endpoint.port, "/html",              false, &ctx.html)
		do_req(handle, endpoint.port, "/json",              false, &ctx.json_get)
		do_req(handle, endpoint.port, "/json",              true,  &ctx.json_head)
		do_req(handle, endpoint.port, "/json-err",          false, &ctx.json_err)
		do_req(handle, endpoint.port, "/chunks",            false, &ctx.chunks)
		do_req(handle, endpoint.port, "/writer",            false, &ctx.writer)
		do_req(handle, endpoint.port, "/writer-unbuffered", false, &ctx.writer_unbuffered)
		do_req(handle, endpoint.port, "/writer-empty",      false, &ctx.writer_empty)
		do_req(handle, endpoint.port, "/writer",            true,  &ctx.writer_head)
		do_req(handle, endpoint.port, "/plain",             false, &ctx.after_keepalive)
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

	check(t, "plain",             &ctx.plain,             200, true,  "text/plain",           "hello plain")
	check(t, "html",              &ctx.html,              200, true,  "text/html",            "<h1>hello</h1>")
	check(t, "json_get",          &ctx.json_get,          200, true,  "application/json",     `{"msg":"ok","count":3}`)
	check(t, "json_head",         &ctx.json_head,         200, true,  "application/json",     "")
	check(t, "json_err",          &ctx.json_err,          500, true,  "text/plain",           "marshal error")
	check(t, "chunks",            &ctx.chunks,            200, false, "",                     "one-two-three")
	check(t, "writer",            &ctx.writer,            200, true,  "application/x-ndjson", "line1\n" + `{"msg":"stream","count":7}`)
	check(t, "writer_unbuffered", &ctx.writer_unbuffered, 200, false, "",                     "alpha-beta")
	check(t, "writer_empty",      &ctx.writer_empty,      200, false, "",                     "")
	check(t, "writer_head",       &ctx.writer_head,       200, true,  "application/x-ndjson", "")
	check(t, "after_keepalive",   &ctx.after_keepalive,   200, true,  "text/plain",           "hello plain")
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
	if arena_err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte); !testing.expect_value(t, arena_err, nil) {
		return
	}
	defer virtual.arena_destroy(&s.temp_allocator_backing)

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
		c.vars.allocator         = tx_alloc
		c.req.headers.allocator  = tx_alloc
		c.res.headers.allocator  = tx_alloc
		c.res.buf.allocator      = tx_alloc
		c.res.deferred.allocator = tx_alloc
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
		c.res.state = .Sending
		c.res.sends = 1

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
		c.res.state = .Sending
		c.res.sends = 2

		op := nbio.Operation{
			type = .Send,
			send = {err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, nil)
		testing.expect_value(t, active_count(&thread), 1)
		testing.expect_value(t, c.res.sends, 1)
		testing.expect(t, c.res.state == .Error, "expected state to transition to .Error")

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
		c.res.state = .Sending
		c.res.sends = 1

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
