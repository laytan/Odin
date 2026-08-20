#+build windows, linux, darwin
package tests_http2

import "base:runtime"

import c "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import http "core:http2"
import "vendor:curl"

Functional_Server :: struct {
	server: http.Server,
}

Curl_Response :: struct {
	body:   [dynamic]byte,
	status: c.long,
}

Curl_Test_Context :: struct {
	t:     ^testing.T,
	state: ^Functional_Server,
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
		port         = 0,
		thread_count = 1,
		handler      = http.handler(http2_test_handler),
	})

	_ = http._setup(&state.server)

	curl_ctx := Curl_Test_Context{t = t, state = &state}
	thread.create_and_start_with_data(&curl_ctx, proc(data: rawptr) {
		ctx := (^Curl_Test_Context)(data)
		t := ctx.t
		s := ctx.state

		endpoint, endpoint_err := nbio.bound_endpoint(s.server.socket)
		if !testing.expectf(t, endpoint_err == nil, "could not query server endpoint: %v", endpoint_err) {
			return
		}

		url := fmt.ctprintf("http://127.0.0.1:%d/ping", endpoint.port)

		curl.global_init(curl.GLOBAL_ALL)
		handle := curl.easy_init()
		if !testing.expect(t, handle != nil, "curl.easy_init failed") {
			return
		}
		defer curl.easy_cleanup(handle)

		response: Curl_Response
		defer delete(response.body)
		testing.expect_value(t, curl.easy_setopt(handle, .URL, url), curl.code.E_OK)
		testing.expect_value(t, curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_response), curl.code.E_OK)
		testing.expect_value(t, curl.easy_setopt(handle, .WRITEDATA, &response), curl.code.E_OK)

		perform_err := curl.easy_perform(handle)
		testing.expectf(t, perform_err == curl.code.E_OK, "curl request failed: %s", curl.easy_strerror(perform_err))

		getinfo_err := curl.easy_getinfo(handle, .RESPONSE_CODE, &response.status)
		testing.expect_value(t, getinfo_err, curl.code.E_OK)
		testing.expect_value(t, response.status, c.long(200))
		testing.expect_value(t, string(response.body[:]), "pong")

		http.server_shutdown(&s.server)
	}, self_cleanup=true)

	http._serve(&state.server)
	http._destroy(&state.server)
}
