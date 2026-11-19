#+build windows, linux, darwin
package tests_http2

import "base:runtime"

import c "core:c/libc"
import "core:fmt"
import "core:net"
import "core:nbio"
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
