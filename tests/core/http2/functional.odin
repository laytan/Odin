#+build windows, linux, darwin
package tests_http2

import "base:runtime"

import c "core:c/libc"
import "core:fmt"
import "core:net"
import "core:nbio"
import "core:strings"
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
