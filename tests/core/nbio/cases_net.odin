#+build linux, darwin, freebsd, windows
package tests_nbio

// TODO: support other BSDs in core:net and enable these tests for them.

import "core:mem"
import "core:nbio"
import "core:net"
import "core:testing"
import "core:time"

@(test)
client_and_server_send_recv :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	testing.set_fail_timeout(t, time.Second)

	server, ep := open_next_available_local_port(t)

	CONTENT :: [20]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}

	State :: struct {
		server:        net.TCP_Socket,
		server_client: net.TCP_Socket,
		client:        net.TCP_Socket,
		recv_buf:      [20]byte,
		send_buf:      [20]byte,
	}

	state := State{
		server   = server,
		send_buf = CONTENT,
	}

	close_ok :: proc(t: ^testing.T, err: nbio.FS_Error) {
		ev(t, err, nil)
	}

	nbio.accept_poly2(server, t, &state, proc(t: ^testing.T, state: ^State, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ev(t, err, nil)

		state.server_client = client

		nbio.recv_all_tcp_poly2(client, state.recv_buf[:], t, state, proc(t: ^testing.T, state: ^State, received: int, err: net.TCP_Recv_Error) {
			ev(t, err, nil)
			ev(t, received, 20)
			ev(t, state.recv_buf, CONTENT)

			nbio.close_poly(state.server_client, t, close_ok)
			nbio.close_poly(state.server, t, close_ok)
		})
	})

	ev(t, nbio.tick(), nil)

	nbio.dial_poly2(ep, t, &state, proc(t: ^testing.T, state: ^State, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)

		state.client = socket

		nbio.send_all_tcp_poly2(socket, state.send_buf[:], t, state, proc(t: ^testing.T, state: ^State, sent: int, err: net.TCP_Send_Error) {
			ev(t, err, nil)
			ev(t, sent, 20)

			nbio.close_poly(state.client, t, close_ok)
		})
	})

	ev(t, nbio.run(), nil)
}

@(test)
close_and_remove_accept :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	testing.set_fail_timeout(t, time.Second)

	server, _ := open_next_available_local_port(t)

	accept := nbio.accept_poly(server, t, proc(t: ^testing.T, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		testing.fail_now(t)
	})

	ev(t, nbio.tick(), nil)

	nbio.close_poly(server, t, proc(t: ^testing.T, err: nbio.FS_Error) {
		ev(t, err, nil)
	})

	nbio.remove(accept)
	ev(t, nbio.run(), nil)
}

@(test)
close_errors_recv :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	testing.set_fail_timeout(t, time.Second)

	server, ep := open_next_available_local_port(t)

	nbio.accept_poly(server, t, proc(t: ^testing.T, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ev(t, err, nil)
		bytes := make([]byte, 128, context.temp_allocator)
		nbio.recv_tcp_poly(client, bytes, t, proc(t: ^testing.T, received: int, err: net.TCP_Recv_Error) {
			ev(t, received, 0)
			ev(t, err, nil)
		})
	})

	ev(t, nbio.tick(), nil)

	nbio.dial_poly(ep, t, proc(t: ^testing.T, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)
		nbio.close_poly(socket, t, proc(t: ^testing.T, err: nbio.FS_Error) {
			ev(t, err, nil)
		})
	})

	ev(t, nbio.run(), nil)
}

@(test)
close_errors_send :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	testing.set_fail_timeout(t, time.Second)

	server, ep := open_next_available_local_port(t)

	nbio.accept_poly(server, t, proc(t: ^testing.T, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ev(t, err, nil)
		bytes := make([]byte, mem.Megabyte * 100, context.temp_allocator)
		nbio.send_all_tcp_poly(client, bytes, t, proc(t: ^testing.T, sent: int, err: net.TCP_Send_Error) {
			ev(t, sent < mem.Megabyte * 100, true)
			ev(t, err, net.TCP_Send_Error.Connection_Closed)
		})
	})

	ev(t, nbio.tick(), nil)

	nbio.dial_poly(ep, t, proc(t: ^testing.T, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)
		nbio.close_poly(socket, t, proc(t: ^testing.T, err: nbio.FS_Error) {
			ev(t, err, nil)
		})
	})

	ev(t, nbio.run(), nil)
}

@(test)
with_timeout :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	sock, _ := open_next_available_local_port(t)

	hit: bool
	accept := nbio.accept_poly2(sock, t, &hit, proc(t: ^testing.T, hit: ^bool, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		hit^ = true
		ev(t, err, net.Accept_Error.Timeout)
	})
	nbio.with_timeout(time.Millisecond, accept)

	ev(t, nbio.run(), nil)

	e(t, hit)
}

@(test)
remove_a_completion_with_a_timeout :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	sock, _ := open_next_available_local_port(t)

	hit_accept: bool
	accept := nbio.accept_poly(sock, &hit_accept, proc(hit_accept: ^bool, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		hit_accept^ = true
	})
	timed_out_accept := nbio.with_timeout(time.Second, accept)

	hit_timeout: bool
	nbio.timeout_poly2(time.Millisecond, timed_out_accept, &hit_timeout, proc(timed_out_accept: ^nbio.Completion, hit_timeout: ^bool) {
		hit_timeout^ = true
		nbio.remove(timed_out_accept)
	})

	ev(t, nbio.run(), nil)

	e(t, !hit_accept)
	e(t, hit_timeout)
}

/*
This test walks through the scenario where a user wants to `poll` in order to check if some other package (in this case `core:net`),
would be able to do an operation without blocking.

It also tests whether a poll can be issues when it is already in a ready state.
And it tests big send/recv buffers being handled properly.
*/
@(test)
test_poll :: proc(t: ^testing.T) {
	if !check_support(t) { return }
	defer nbio.destroy()

	can_recv: bool

	sock, ep := open_next_available_local_port(t)

	/* -- Server -- */

	nbio.accept_poly2(sock, t, &can_recv, proc(t: ^testing.T, can_recv: ^bool, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ev(t, err, nil)

		check_recv :: proc(t: ^testing.T, can_recv: ^bool, client: net.TCP_Socket) {
			// Not ready to unblock the client yet, requeue for after 10ms.
			if !can_recv^ {
				nbio.timeout_poly3(time.Millisecond * 10, t, can_recv, client, check_recv)
				return
			}

			// Receive some data to unblock the client, which should complete the poll it does, allowing it to send data again.
			buf, mem_err := make([]byte, mem.Gigabyte * 2, context.temp_allocator)
			ev(t, mem_err, nil)
			nbio.recv_all_tcp_poly2(client, buf, t, client, proc(t: ^testing.T, client: net.TCP_Socket, received: int, err: net.TCP_Recv_Error) {
				ev(t, err, nil)
				nbio.close(client)
			})
		}
		nbio.timeout_poly3(time.Millisecond * 10, t, can_recv, client, check_recv)
	})

	/* -- Client -- */

	// Do a poll even though we know it's ready, so we can test that all implementations can handle that.
	nbio.dial_poly2(ep, t, &can_recv, proc(t: ^testing.T, can_recv: ^bool, sock: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)

		nbio.poll_poly3(sock, .Write, false, t, sock, can_recv, proc(t: ^testing.T, sock: net.TCP_Socket, can_recv: ^bool, res: nbio.Poll_Result) {
			ev(t, res, nil)

			// Send 4 GB of data, which in my experience causes a Would_Block error because we filled up the internal buffer.
			buf, mem_err := make([]byte, mem.Gigabyte*4, context.temp_allocator)
			ev(t, mem_err, nil)
			_, send_err := net.send_tcp(sock, buf)
			ev(t, send_err, net.TCP_Send_Error.Would_Block)

			// Tell the server it can start issueing recv calls, so it unblocks us.
			can_recv^ = true

			// Now poll again, when the server reads enough data it should complete, telling us we can send without blocking again.
			nbio.poll_poly3(sock, .Write, false, t, sock, can_recv, proc(t: ^testing.T, sock: net.TCP_Socket, can_recv: ^bool, res: nbio.Poll_Result) {
				ev(t, res, nil)

				buf: [128]byte
				bytes_written, send_err := net.send_tcp(sock, buf[:])
				ev(t, bytes_written, 128)
				ev(t, send_err, nil)

				nbio.close(sock)
			})
		})
	})

	ev(t, nbio.run(), nil)
	nbio.close(sock)
	ev(t, nbio.run(), nil)
}
