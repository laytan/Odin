#+build !riscv64
package tests_client

// TODO: make the CI able to run this test on RISCV, it should be able to run fine, besides that
// the CI now does a static linking trick and this test needs openssl, which is dynamically linked.

import "core:http"
import "core:log"
import "core:nbio"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

ev :: testing.expect_value

require_value :: proc(t: ^testing.T, val: $T, test: T, format := "", args: ..any, loc := #caller_location) {
	if !testing.expect_value(t, val, test, loc) {
		testing.fail_now(t, fmt.tprintf(format, ..args), loc)
	}
}

rv :: require_value

listen_next_available_local_port :: proc(t: ^testing.T, s: ^http.Server, opts := http.Default_Server_Opts) -> (ep: net.Endpoint, err: net.Network_Error) {
	http.listen(s, {net.IP4_Loopback, 0}, opts) or_return
	return net.bound_endpoint(s.tcp_sock)
}

// Send a simple request and expect OK.
// @(test)
// test_ok :: proc(tt: ^testing.T) {
// 	testing.set_fail_timeout(tt, time.Second * 10)
//
// 	@static s: http.Server
// 	@static t: ^testing.T
// 	t = tt
//
// 	opts := http.Default_Server_Opts
// 	opts.thread_count = 0
//
// 	ep, err := listen_next_available_local_port(t, &s, opts)
// 	if err == net.Create_Socket_Error.Network_Unreachable {
// 		log.warn("network unreachable, probably unsupported target, skipping test")
// 		return
// 	}
// 	ev(t, err, nil)
//
// 	///
//
// 	client: http.Client
// 	http.client_init(&client)
//
// 	req := http.get(net.endpoint_to_string(ep))
//
// 	http.request(&client, http.get(net.endpoint_to_string(ep), &client, proc(req: http.Client_Request, res: ^http.Client_Response, err: http.Request_Error) {
// 		client := (^http.Client)(req.user_data)
//
// 		ev(t, err, nil)
// 		ev(t, res.status, http.Status.OK)
// 		ev(t, http.headers_has(res.headers, "date"), true)
// 		ev(t, http.headers_has(res.headers, "content-length"), true)
// 		ev(t, len(res.body), 0)
//
// 		log.info("cleaning up")
//
// 		http.response_destroy(client, res^)
// 		http.client_destroy(client)
// 		http.server_shutdown(&s) // NOTE: this takes a bit because of the close delay.
// 	}))
//
// 	///
//
// 	handler := http.handler(proc(ctx: ^http.Context) {
// 		ctx.res.status = .OK
// 		log.info("responding")
// 		http.respond(ctx.res)
// 	})
// 	ev(t, http.serve(&s, handler), nil)
// }

// // Send two requests, assert two connections are opened, then send two more requests, assert the same
// // two connections are reused.
// @(test)
// connection_pool :: proc(t: ^testing.T) {
// 	testing.set_fail_timeout(t, time.Second * 10)
//
// 	State :: struct {
// 		s:         http.Server,
// 		ep:        net.Endpoint,
// 		listening: sync.One_Shot_Event,
// 	}
// 	s: State
//
// 	server_thread := thread.create_and_start_with_poly_data2(t, &s, proc(t: ^testing.T, s: ^State) {
// 		opts := http.Default_Server_Opts
// 		opts.thread_count = 0
//
// 		handler := http.handler(proc(ctx: ^http.Context) {
// 			ctx.res.status = .OK
// 			http.respond(ctx.res)
// 		})
//
// 		err: net.Network_Error
// 		s.ep, err = listen_next_available_local_port(t, &s.s, opts)
// 		if err == net.Create_Socket_Error.Network_Unreachable {
// 			log.warn("network unreachable, probably unsupported target, skipping test")
// 			return
// 		}
// 		ev(t, err, nil)
//
// 		sync.one_shot_event_signal(&s.listening)
//
// 		ev(t, http.serve(&s.s, handler), nil)
// 	}, init_context=context)
// 	defer thread.destroy(server_thread)
//
// 	@static client: http.Client
// 	if !http.client_init(&client) {
// 		log.warn("could not initialize http client, probably unsupported target, skipping test")
// 		return
// 	}
//
// 	sync.one_shot_event_wait(&s.listening)
//
// 	req := http.get(net.endpoint_to_string(s.ep))
//
// 	for _ in 0..<2 {
// 		http.request(&client, req, t, on_response)
// 		http.request(&client, req, t, on_response)
//
// 		on_response :: proc(res: http.Client_Response, t: rawptr, err: http.Request_Error) {
// 			t := (^testing.T)(t)
//
// 			ev(t, err, nil)
// 			ev(t, res.status, http.Status.OK)
// 			ev(t, http.headers_has(res.headers, "date"), true)
// 			ev(t, http.headers_has(res.headers, "content-length"), true)
// 			ev(t, len(res.body), 0)
//
// 			http.response_destroy(&client, res)
// 		}
//
// 		ev(t, nbio.run(), nil)
//
// 		ev(t, len(client.conns), 1)
// 		for _, conns in client.conns {
// 			ev(t, len(conns), 2)
// 		}
// 	}
//
// 	http.client_destroy(&client)
// 	ev(t, nbio.run(), nil)
//
// 	http.server_shutdown(&s.s)
// }
//
// // Send a request, server closes the connection after successfully responding, client sends another
// // request, make sure that all goes well.
// @(test)
// test_server_closes_after_ok :: proc(t: ^testing.T) {
// 	testing.set_fail_timeout(t, time.Second * 10)
//
// 	State :: struct {
// 		s: http.Server,
// 		t: ^testing.T,
// 		client: http.Client,
// 		req: http.Client_Request,
// 		sent_second_request: bool,
// 	}
// 	@static state: State
// 	state = State{
// 		t = t,
// 	}
//
// 	opts := http.Default_Server_Opts
// 	opts.thread_count = 0
//
// 	ep, err := listen_next_available_local_port(t, &state.s, opts)
// 	if err == net.Create_Socket_Error.Network_Unreachable {
// 		log.warn("network unreachable, probably unsupported target, skipping test")
// 		return
// 	}
// 	ev(t, err, nil)
//
// 	///
//
// 	http.client_init(&state.client)
//
// 	state.req = http.get(net.endpoint_to_string(ep))
//
// 	http.request(&state.client, state.req, rawptr(nil), proc(res: http.Client_Response, user: rawptr, err: http.Request_Error) {
// 		ev(state.t, err, nil)
// 		ev(state.t, res.status, http.Status.OK)
// 		ev(state.t, http.headers_has(res.headers, "date"), true)
// 		ev(state.t, http.headers_has(res.headers, "content-length"), true)
// 		ev(state.t, len(res.body), 0)
// 		log.info("Got first response")
//
// 		http.response_destroy(&state.client, res)
// 	})
//
// 	send_second_request :: proc(_: rawptr) {
// 		http.request(&state.client, state.req, rawptr(nil), proc(res: http.Client_Response, user: rawptr, err: http.Request_Error) {
// 			ev(state.t, err, nil)
// 			ev(state.t, res.status, http.Status.OK)
// 			ev(state.t, http.headers_has(res.headers, "date"), true)
// 			ev(state.t, http.headers_has(res.headers, "content-length"), true)
// 			ev(state.t, len(res.body), 0)
// 			log.info("Got second response")
//
// 			http.response_destroy(&state.client, res)
// 			http.client_destroy(&state.client)
// 			http.server_shutdown(&state.s) // NOTE: this takes a bit because of the close delay.
// 		})
// 	}
//
// 	///
//
// 	handler := http.handler(proc(ctx: ^http.Context) {
// 		ctx.res.status = .OK
//
// 		ctx.res.on_sent = proc(c: ^http.Connection, ud: rawptr) {
// 			if state.sent_second_request {
// 				return
// 			}
// 			state.sent_second_request = true
//
// 			http.close_eventually(c)
//
// 			// NOTE: On a timeout send the next request, closing a connection takes time.
// 			nbio.timeout(http.Conn_Close_Delay, rawptr(nil), send_second_request)
//
// 			log.info("closing")
// 		}
//
// 		log.info("responding")
// 		http.respond(ctx.res)
// 	})
// 	ev(t, http.serve(&state.s, handler), nil)
// }
