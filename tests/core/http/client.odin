package tests_client

import "core:http"
import "core:nbio"
import "core:log"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"

ev :: testing.expect_value

require_value :: proc(t: ^testing.T, val: $T, test: T, format := "", args: ..any, loc := #caller_location) {
	if !testing.expect_value(t, val, test, loc) {
		testing.fail_now(t, fmt.tprintf(format, ..args), loc)
	}
}

rv :: require_value

listen_next_available_local_port :: proc(t: ^testing.T, s: ^http.Server, opts := http.Default_Server_Opts, loc := #caller_location) -> (ep: net.Endpoint) {
	@static mu: sync.Mutex
	sync.guard(&mu)

	for {
		PORT_START :: 1999
		@static port := PORT_START

		port += 1
		ep = {net.IP4_Loopback, port}

		err := http.listen(s, ep, opts)
		if err != nil {
			if err == net.Dial_Error.Address_In_Use {
				log.infof("endpoint %v in use, trying next port", ep, location=loc)
				continue
			}

			log.panicf("http.listen failed: %v", err, location=loc)
		}

		return
	}
}

// Send a simple request and expect OK.
@(test)
test_ok :: proc(tt: ^testing.T) {
	@static s: http.Server
	@static t: ^testing.T
	t = tt

	opts := http.Default_Server_Opts
	opts.thread_count = 0

	ep := listen_next_available_local_port(t, &s, opts)

	///

	client: http.Client
	http.client_init(&client, http.io())

	req := http.Client_Request{
		url = net.endpoint_to_string(ep),
	}

	http.client_request(&client, req, &client, proc(res: http.Client_Response, user: rawptr, err: http.Request_Error) {
		client := (^http.Client)(user)

		ev(t, err, nil)
		ev(t, res.status, http.Status.OK)
		ev(t, http.headers_has_unsafe(res.headers, "date"), true)
		ev(t, http.headers_has_unsafe(res.headers, "content-length"), true)
		ev(t, len(res.body), 0)

		log.info("cleaning up")

		http.response_destroy(client, res)
		http.client_destroy(client)
		http.server_shutdown(&s) // NOTE: this takes a bit because of the close delay.
	})

	///

	handler := http.handler(proc(_: ^http.Request, res: ^http.Response) {
		res.status = .OK
		http.respond(res)
	})
	ev(t, http.serve(&s, handler), nil)
}

// Send two requests, assert two connections are opened, then send two more requests, assert the same
// two connections are reused.
@(test)
connection_pool :: proc(t: ^testing.T) {
	State :: struct {
		s:         http.Server,
		ep:        net.Endpoint,
		listening: sync.One_Shot_Event,
	}
	s: State

	server_thread := thread.create_and_start_with_poly_data2(t, &s, proc(t: ^testing.T, s: ^State) {
		opts := http.Default_Server_Opts
		opts.thread_count = 0

		handler := http.handler(proc(_: ^http.Request, res: ^http.Response) {
			res.status = .OK
			http.respond(res)
		})

		s.ep = listen_next_available_local_port(t, &s.s, opts)

		sync.one_shot_event_signal(&s.listening)

		ev(t, http.serve(&s.s, handler), nil)
	}, init_context=context)
	defer thread.destroy(server_thread)

	io: nbio.IO
	ev(t, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	@static client: http.Client
	http.client_init(&client, &io)

	sync.one_shot_event_wait(&s.listening)

	req := http.Client_Request{
		url = net.endpoint_to_string(s.ep),
	}

	for _ in 0..<2 {
		http.client_request(&client, req, t, on_response)
		http.client_request(&client, req, t, on_response)

		on_response :: proc(res: http.Client_Response, t: rawptr, err: http.Request_Error) {
			t := (^testing.T)(t)
			ev(t, err, nil)
			ev(t, res.status, http.Status.OK)
			ev(t, http.headers_has_unsafe(res.headers, "date"), true)
			ev(t, http.headers_has_unsafe(res.headers, "content-length"), true)
			ev(t, len(res.body), 0)

			http.response_destroy(&client, res)
		}

		ev(t, nbio.run(&io), os.ERROR_NONE)

		ev(t, len(client.conns), 1)
		for _, conns in client.conns {
			ev(t, len(conns), 2)
		}
	}

	http.client_destroy(&client)
	ev(t, nbio.run(&io), os.ERROR_NONE)

	http.server_shutdown(&s.s)
}

// Send a request, server closes the connection after successfully responding, client sends another
// request, make sure that all goes well.
@(test)
test_server_closes_after_ok :: proc(t: ^testing.T) {
	State :: struct {
		s: http.Server,
		t: ^testing.T,
		client: http.Client,
		req: http.Client_Request,
		sent_second_request: bool,
	}
	@static state: State
	state = State{
		t = t,
	}

	opts := http.Default_Server_Opts
	opts.thread_count = 0

	ep := listen_next_available_local_port(t, &state.s, opts)

	///

	http.client_init(&state.client, http.io())

	state.req = http.Client_Request{
		url = net.endpoint_to_string(ep),
	}

	http.client_request(&state.client, state.req, rawptr(nil), proc(res: http.Client_Response, user: rawptr, err: http.Request_Error) {
		ev(state.t, err, nil)
		ev(state.t, res.status, http.Status.OK)
		ev(state.t, http.headers_has_unsafe(res.headers, "date"), true)
		ev(state.t, http.headers_has_unsafe(res.headers, "content-length"), true)
		ev(state.t, len(res.body), 0)
		log.info("Got first response")

		http.response_destroy(&state.client, res)
	})

	send_second_request :: proc(_: rawptr) {
		http.client_request(&state.client, state.req, rawptr(nil), proc(res: http.Client_Response, user: rawptr, err: http.Request_Error) {
			ev(state.t, err, nil)
			ev(state.t, res.status, http.Status.OK)
			ev(state.t, http.headers_has_unsafe(res.headers, "date"), true)
			ev(state.t, http.headers_has_unsafe(res.headers, "content-length"), true)
			ev(state.t, len(res.body), 0)
			log.info("Got second response")

			http.response_destroy(&state.client, res)
			http.client_destroy(&state.client)
			http.server_shutdown(&state.s) // NOTE: this takes a bit because of the close delay.
		})
	}

	///

	handler := http.handler(proc(_: ^http.Request, res: ^http.Response) {
		res.status = .OK

		res.on_sent = proc(c: ^http.Connection, ud: rawptr) {
			if state.sent_second_request {
				return
			}
			state.sent_second_request = true

			http._connection_close(c)

			// NOTE: On a timeout send the next request, closing a connection takes time.
			nbio.timeout(http.io(), http.Conn_Close_Delay, rawptr(nil), send_second_request)
		}

		http.respond(res)
	})
	ev(t, http.serve(&state.s, handler), nil)
}
