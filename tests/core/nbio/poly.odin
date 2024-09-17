package tests_nbio

import "core:nbio"
import "core:net"
import "core:os"
import "core:testing"

ev :: testing.expect_value
e  :: testing.expect

// Tests that all poly variants are correctly passing through arguments, and that
// all procs eventually get their callback called.
@(test)
all_poly_work :: proc(tt: ^testing.T) {
	@static t: ^testing.T
	t = tt

	@static n: int
	n = 0

	nbio.timeout_poly(0, 1, proc(one: int) {
		ev(t, one, 1)
	})
	nbio.timeout_poly2(0, 1, 2, proc(one: int, two: int) {
		ev(t, one, 1)
		ev(t, two, 2)
	})
	nbio.timeout_poly3(0, 1, 2, 3, proc(one: int, two: int, three: int) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	})

	nbio.close_poly(os.INVALID_HANDLE, 1, proc(one: int, ok: bool) {
		ev(t, one, 1)
		ev(t, ok, false)
	})
	nbio.close_poly2(os.INVALID_HANDLE, 1, 2, proc(one: int, two: int, ok: bool) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, ok, false)
	})
	nbio.close_poly3(os.INVALID_HANDLE, 1, 2, 3, proc(one: int, two: int, three: int, ok: bool) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		ev(t, ok, false)
	})

	nbio.accept_poly(0, 1, proc(one: int, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, one, 1)
		e(t, err != nil)
	})
	nbio.accept_poly2(0, 1, 2, proc(one: int, two: int, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		e(t, err != nil)
	})
	nbio.accept_poly3(0, 1, 2, 3, proc(one: int, two: int, three: int, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		e(t, err != nil)
	})

	nbio.connect_poly({net.IP4_Address{127, 0, 0, 1}, 80}, 1, proc(one: int, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, one, 1)
		nbio.close(socket)
	})
	nbio.connect_poly2({net.IP4_Address{127, 0, 0, 1}, 80}, 1, 2, proc(one: int, two: int, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		nbio.close(socket)
	})
	nbio.connect_poly3({net.IP4_Address{127, 0, 0, 1}, 80}, 1, 2, 3, proc(one: int, two: int, three: int, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		nbio.close(socket)
	})

	on_recv1 :: proc(one: int, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		ev(t, one, 1)
	}
	on_recv2 :: proc(one: int, two: int, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_recv3 :: proc(one: int, two: int, three: int, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.recv_poly (net.TCP_Socket(0), nil, 1, on_recv1)
	nbio.recv_poly2(net.TCP_Socket(0), nil, 1, 2, on_recv2)
	nbio.recv_poly3(net.TCP_Socket(0), nil, 1, 2, 3, on_recv3)

	nbio.recv_all_poly (net.TCP_Socket(0), nil, 1, on_recv1)
	nbio.recv_all_poly2(net.TCP_Socket(0), nil, 1, 2, on_recv2)
	nbio.recv_all_poly3(net.TCP_Socket(0), nil, 1, 2, 3, on_recv3)

	on_send1 :: proc(one: int, sent: int, err: net.Network_Error) {
		ev(t, one, 1)
		e(t, err != nil)
	}
	on_send2 :: proc(one: int, two: int, sent: int, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		e(t, err != nil)
	}
	on_send3 :: proc(one: int, two: int, three: int, sent: int, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		e(t, err != nil)
	}

	nbio.send_tcp_poly (0, nil, 1, on_send1)
	nbio.send_tcp_poly2(0, nil, 1, 2, on_send2)
	nbio.send_tcp_poly3(0, nil, 1, 2, 3, on_send3)

	nbio.send_udp_poly (net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, on_send1)
	nbio.send_udp_poly2(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, on_send2)
	nbio.send_udp_poly3(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, 3, on_send3)

	nbio.send_all_tcp_poly (0, nil, 1, on_send1)
	nbio.send_all_tcp_poly2(0, nil, 1, 2, on_send2)
	nbio.send_all_tcp_poly3(0, nil, 1, 2, 3, on_send3)

	nbio.send_all_udp_poly (net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, on_send1)
	nbio.send_all_udp_poly2(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, on_send2)
	nbio.send_all_udp_poly3(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, 3, on_send3)

	on_read1 :: proc(one: int, read: int, err: os.Errno) {
		ev(t, one, 1)
	}
	on_read2 :: proc(one: int, two: int, read: int, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_read3 :: proc(one: int, two: int, three: int, read: int, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.read_at_poly (os.INVALID_HANDLE, 0, nil, 1, on_read1)
	nbio.read_at_poly2(os.INVALID_HANDLE, 0, nil, 1, 2, on_read2)
	nbio.read_at_poly3(os.INVALID_HANDLE, 0, nil, 1, 2, 3, on_read3)

	nbio.read_at_all_poly (os.INVALID_HANDLE, 0, nil, 1, on_read1)
	nbio.read_at_all_poly2(os.INVALID_HANDLE, 0, nil, 1, 2, on_read2)
	nbio.read_at_all_poly3(os.INVALID_HANDLE, 0, nil, 1, 2, 3, on_read3)

	on_write1 :: proc(one: int, written: int, err: os.Errno) {
		ev(t, one, 1)
	}
	on_write2 :: proc(one: int, two: int, written: int, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_write3 :: proc(one: int, two: int, three: int, written: int, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.write_at_poly (os.INVALID_HANDLE, 0, nil, 1, on_write1)
	nbio.write_at_poly2(os.INVALID_HANDLE, 0, nil, 1, 2, on_write2)
	nbio.write_at_poly3(os.INVALID_HANDLE, 0, nil, 1, 2, 3, on_write3)

	nbio.write_at_all_poly (os.INVALID_HANDLE, 0, nil, 1, on_write1)
	nbio.write_at_all_poly2(os.INVALID_HANDLE, 0, nil, 1, 2, on_write2)
	nbio.write_at_all_poly3(os.INVALID_HANDLE, 0, nil, 1, 2, 3, on_write3)

	nbio.next_tick_poly(1, proc(one: int) {
		ev(t, one, 1)
	})
	nbio.next_tick_poly2(1, 2, proc(one: int, two: int) {
		ev(t, one, 1)
		ev(t, two, 2)
	})
	nbio.next_tick_poly3(1, 2, 3, proc(one: int, two: int, three: int) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	})

	nbio.poll_poly(os.INVALID_HANDLE, .Read, false, 1, proc(one: int, event: nbio.Poll_Event) {
		ev(t, one, 1)
	})
	nbio.poll_poly2(os.INVALID_HANDLE, .Read, false, 1, 2, proc(one: int, two: int, event: nbio.Poll_Event) {
		ev(t, one, 1)
		ev(t, two, 2)
	})
	nbio.poll_poly3(os.INVALID_HANDLE, .Read, false, 1, 2, 3, proc(one: int, two: int, three: int, event: nbio.Poll_Event) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	})

	ev(t, nbio.run(), os.ERROR_NONE)
}

@(test)
read_entire_file_works :: proc(tt: ^testing.T) {
	@static t: ^testing.T
	t = tt

	fd, errno := nbio.open(#file)
	ev(t, errno, os.ERROR_NONE)

	nbio.read_entire_file(fd, 1, proc(one: int, buf: []byte, err: os.Errno) {
		ev(t, one, 1)
		ev(t, err, os.ERROR_NONE)
		ev(t, string(buf), #load(#file, string))
		delete(buf)
	})

	nbio.read_entire_file2(fd, 1, 2, proc(one: int, two: int, buf: []byte, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, err, os.ERROR_NONE)
		ev(t, string(buf), #load(#file, string))
		delete(buf)
	})

	nbio.read_entire_file3(fd, 1, 2, 3, proc(one: int, two: int, three: int, buf: []byte, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		ev(t, err, os.ERROR_NONE)
		ev(t, string(buf), #load(#file, string))
		delete(buf)
	})

	ev(t, nbio.run(), os.ERROR_NONE)

	nbio.close(fd)

	ev(t, nbio.run(), os.ERROR_NONE)
}
