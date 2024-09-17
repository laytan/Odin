package tests_nbio

import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

open_next_available_local_port :: proc(t: ^testing.T, loc := #caller_location) -> (sock: net.TCP_Socket, ep: net.Endpoint) {
	@static mu: sync.Mutex
	sync.guard(&mu)

	for {
		PORT_START :: 1999
		@static port := PORT_START

		port += 1
		ep = {net.IP4_Loopback, port}

		err: net.Network_Error
		sock, err = nbio.open_and_listen_tcp(ep)
		if err != nil {
			if err == net.Dial_Error.Address_In_Use {
				log.infof("endpoint %v in use, trying next port", ep, location=loc)
				continue
			}

			log.panicf("nbio.open_and_listen_tcp failed: %v", err, location=loc)
		}

		return
	}
}

@(test)
close_invalid_handle_works :: proc(t: ^testing.T) {
	nbio.close_poly(os.INVALID_HANDLE, t, proc(t: ^testing.T, ok: bool) {
		ev(t, ok, false)
	})

	ev(t, nbio.run(), os.ERROR_NONE)
}

@(test)
timeout_runs_in_reasonable_time :: proc(t: ^testing.T) {
	start := time.now()

	nbio.timeout(time.Millisecond * 10, rawptr(nil), proc(_: rawptr) {})

	ev(t, nbio.run(), os.ERROR_NONE)

	duration := time.since(start)
	e(t, duration < time.Millisecond * 11)
}

@(test)
write_read_close :: proc(t: ^testing.T) {
	handle, errno := nbio.open(
		"test_write_read_close",
		os.O_RDWR | os.O_CREATE | os.O_TRUNC,
		os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH when ODIN_OS != .Windows else 0,
	)
	ev(t, errno, os.ERROR_NONE)

	State :: struct {
		buf: [20]byte,
		fd:  os.Handle,
	}

	CONTENT :: [20]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}

	state := State{
		buf = CONTENT,
		fd = handle,
	}

	nbio.write_entire_file2(handle, state.buf[:], t, &state, proc(t: ^testing.T, state: ^State, written: int, err: os.Errno) {
		ev(t, written, len(state.buf))
		ev(t, err, os.ERROR_NONE)

		nbio.read_at_all_poly2(state.fd, 0, state.buf[:], t, state, proc(t: ^testing.T, state: ^State, read: int, err: os.Errno) {
			ev(t, read, len(state.buf))
			ev(t, err, os.ERROR_NONE)
			ev(t, state.buf, CONTENT)

			nbio.close_poly2(state.fd, t, state, proc(t: ^testing.T, state: ^State, ok: bool) {
				ev(t, ok, true)
				os.remove("test_write_read_close")
			})
		})
	})

	ev(t, nbio.run(), os.ERROR_NONE)
}

@(test)
client_and_server_send_recv :: proc(t: ^testing.T) {
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

	close_ok :: proc(t: ^testing.T, ok: bool) {
		ev(t, ok, true)
	}

	nbio.accept_poly2(server, t, &state, proc(t: ^testing.T, state: ^State, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, err, nil)

		state.server_client = client

		nbio.recv_all_poly2(client, state.recv_buf[:], t, state, proc(t: ^testing.T, state: ^State, received: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
			ev(t, err, nil)
			ev(t, received, 20)
			ev(t, state.recv_buf, CONTENT)

			nbio.close_poly(state.server_client, t, close_ok)
			nbio.close_poly(state.server, t, close_ok)
		})
	})

	ev(t, nbio.tick(), os.ERROR_NONE)

	nbio.connect_poly2(ep, t, &state, proc(t: ^testing.T, state: ^State, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)

		state.client = socket

		nbio.send_all_tcp_poly2(socket, state.send_buf[:], t, state, proc(t: ^testing.T, state: ^State, sent: int, err: net.Network_Error) {
			ev(t, err, nil)
			ev(t, sent, 20)

			nbio.close_poly(state.client, t, close_ok)
		})
	})

	ev(t, nbio.run(), os.ERROR_NONE)
}

@(test)
close_and_remove_accept :: proc(t: ^testing.T) {
	server, _ := open_next_available_local_port(t)

	accept := nbio.accept_poly(server, t, proc(t: ^testing.T, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		testing.fail_now(t)
	})

	ev(t, nbio.tick(), os.ERROR_NONE)

	nbio.close_poly(server, t, proc(t: ^testing.T, ok: bool) {
		ev(t, ok, true)
	})

	nbio.remove(accept)

	ev(t, nbio.run(), os.ERROR_NONE)
}

@(test)
close_errors_recv :: proc(t: ^testing.T) {
	server, ep := open_next_available_local_port(t)

	nbio.accept_poly(server, t, proc(t: ^testing.T, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, err, nil)
		bytes := make([]byte, 128, context.temp_allocator)
		nbio.recv_poly(client, bytes, t, proc(t: ^testing.T, received: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
			ev(t, received, 0)
			ev(t, err, nil)
		})
	})

	ev(t, nbio.tick(), os.ERROR_NONE)

	nbio.connect_poly(ep, t, proc(t: ^testing.T, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)
		nbio.close_poly(socket, t, proc(t: ^testing.T, ok: bool) {
			ev(t, ok, true)
		})
	})

	ev(t, nbio.run(), os.ERROR_NONE)
}

@(test)
close_errors_send :: proc(t: ^testing.T) {
	server, ep := open_next_available_local_port(t)

	nbio.accept_poly(server, t, proc(t: ^testing.T, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, err, nil)
		bytes := make([]byte, mem.Megabyte * 100, context.temp_allocator)
		nbio.send_all_tcp_poly(client, bytes, t, proc(t: ^testing.T, sent: int, err: net.Network_Error) {
			ev(t, sent < mem.Megabyte * 100, true)
			ev(t, err, net.TCP_Send_Error.Connection_Closed)
		})
	})

	ev(t, nbio.tick(), os.ERROR_NONE)

	nbio.connect_poly(ep, t, proc(t: ^testing.T, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)
		nbio.close_poly(socket, t, proc(t: ^testing.T, ok: bool) {
			ev(t, ok, true)
		})
	})

	ev(t, nbio.run(), os.ERROR_NONE)
}

@(test)
usage_across_threads :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, time.Second * 10)

	handle: os.Handle
	thread_done: sync.One_Shot_Event

	open_thread := thread.create_and_start_with_poly_data3(t, &handle, &thread_done, proc(t: ^testing.T, handle: ^os.Handle, thread_done: ^sync.One_Shot_Event) {
		fd, errno := nbio.open(#file)
		ev(t, errno, os.ERROR_NONE)

		handle^ = fd

		sync.one_shot_event_signal(thread_done)
	}, init_context=context)

	sync.one_shot_event_wait(&thread_done)
	thread.destroy(open_thread)

	buf: [128]byte
	nbio.read_at_poly(handle, 0, buf[:], t, proc(t: ^testing.T, read: int, errno: os.Errno) {
		ev(t, errno, os.ERROR_NONE)
		e(t, read > 0)
	})

	nbio.run()
}
