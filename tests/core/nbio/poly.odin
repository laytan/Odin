package tests_nbio

import "core:nbio"
import "core:net"
import "core:testing"

// Tests that all poly variants are correctly passing through arguments, and that
// all procs eventually get their callback called.
@(test)
all_poly_work :: proc(tt: ^testing.T) {
	if !check_support(tt) { return }
	defer nbio.destroy()

	@static t: ^testing.T
	t = tt

	@static n: int
	n = 0

	UDP_SOCKET :: max(net.UDP_Socket)
	TCP_SOCKET :: max(net.TCP_Socket)
	HANDLE     :: max(nbio.Handle)

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

	nbio.close_poly(HANDLE, 1, proc(one: int, err: nbio.FS_Error) {
		ev(t, one, 1)
		e(t, err != nil)
	})
	nbio.close_poly2(HANDLE, 1, 2, proc(one: int, two: int, err: nbio.FS_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		e(t, err != nil)
	})
	nbio.close_poly3(HANDLE, 1, 2, 3, proc(one: int, two: int, three: int, err: nbio.FS_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		e(t, err != nil)
	})

	nbio.accept_poly(TCP_SOCKET, 1, proc(one: int, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ev(t, one, 1)
		e(t, err != nil)
	})
	nbio.accept_poly2(TCP_SOCKET, 1, 2, proc(one: int, two: int, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		e(t, err != nil)
	})
	nbio.accept_poly3(TCP_SOCKET, 1, 2, 3, proc(one: int, two: int, three: int, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		e(t, err != nil)
	})

	nbio.dial_poly({net.IP4_Address{127, 0, 0, 1}, 80}, 1, proc(one: int, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, one, 1)
		e(t, err != nil)
	})
	nbio.dial_poly2({net.IP4_Address{127, 0, 0, 1}, 80}, 1, 2, proc(one: int, two: int, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		e(t, err != nil)
	})
	nbio.dial_poly3({net.IP4_Address{127, 0, 0, 1}, 80}, 1, 2, 3, proc(one: int, two: int, three: int, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		e(t, err != nil)
	})

	on_recv_tcp1 :: proc(one: int, received: int, err: net.TCP_Recv_Error) {
		ev(t, one, 1)
	}
	on_recv_tcp2 :: proc(one: int, two: int, received: int, err: net.TCP_Recv_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_recv_tcp3 :: proc(one: int, two: int, three: int, received: int, err: net.TCP_Recv_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.recv_tcp_poly (TCP_SOCKET, nil, 1, on_recv_tcp1)
	nbio.recv_tcp_poly2(TCP_SOCKET, nil, 1, 2, on_recv_tcp2)
	nbio.recv_tcp_poly3(TCP_SOCKET, nil, 1, 2, 3, on_recv_tcp3)

	nbio.recv_all_tcp_poly (TCP_SOCKET, nil, 1, on_recv_tcp1)
	nbio.recv_all_tcp_poly2(TCP_SOCKET, nil, 1, 2, on_recv_tcp2)
	nbio.recv_all_tcp_poly3(TCP_SOCKET, nil, 1, 2, 3, on_recv_tcp3)

	on_recv_udp1 :: proc(one: int, received: int, client: net.Endpoint, err: net.UDP_Recv_Error) {
		ev(t, one, 1)
	}
	on_recv_udp2 :: proc(one: int, two: int, received: int, client: net.Endpoint, err: net.UDP_Recv_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_recv_udp3 :: proc(one: int, two: int, three: int, received: int, client: net.Endpoint, err: net.UDP_Recv_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.recv_udp_poly (UDP_SOCKET, nil, 1, on_recv_udp1)
	nbio.recv_udp_poly2(UDP_SOCKET, nil, 1, 2, on_recv_udp2)
	nbio.recv_udp_poly3(UDP_SOCKET, nil, 1, 2, 3, on_recv_udp3)

	nbio.recv_all_udp_poly (UDP_SOCKET, nil, 1, on_recv_udp1)
	nbio.recv_all_udp_poly2(UDP_SOCKET, nil, 1, 2, on_recv_udp2)
	nbio.recv_all_udp_poly3(UDP_SOCKET, nil, 1, 2, 3, on_recv_udp3)

	on_send_tcp1 :: proc(one: int, sent: int, err: net.TCP_Send_Error) {
		ev(t, one, 1)
		e(t, err != nil)
	}
	on_send_tcp2 :: proc(one: int, two: int, sent: int, err: net.TCP_Send_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		e(t, err != nil)
	}
	on_send_tcp3 :: proc(one: int, two: int, three: int, sent: int, err: net.TCP_Send_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		e(t, err != nil)
	}

	on_send_udp1 :: proc(one: int, sent: int, err: net.UDP_Send_Error) {
		ev(t, one, 1)
		e(t, err != nil)
	}
	on_send_udp2 :: proc(one: int, two: int, sent: int, err: net.UDP_Send_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		e(t, err != nil)
	}
	on_send_udp3 :: proc(one: int, two: int, three: int, sent: int, err: net.UDP_Send_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		e(t, err != nil)
	}

	nbio.send_tcp_poly (TCP_SOCKET, nil, 1, on_send_tcp1)
	nbio.send_tcp_poly2(TCP_SOCKET, nil, 1, 2, on_send_tcp2)
	nbio.send_tcp_poly3(TCP_SOCKET, nil, 1, 2, 3, on_send_tcp3)

	nbio.send_udp_poly (net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, on_send_udp1)
	nbio.send_udp_poly2(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, on_send_udp2)
	nbio.send_udp_poly3(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, 3, on_send_udp3)

	nbio.send_all_tcp_poly (TCP_SOCKET, nil, 1, on_send_tcp1)
	nbio.send_all_tcp_poly2(TCP_SOCKET, nil, 1, 2, on_send_tcp2)
	nbio.send_all_tcp_poly3(TCP_SOCKET, nil, 1, 2, 3, on_send_tcp3)

	nbio.send_all_udp_poly (net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, on_send_udp1)
	nbio.send_all_udp_poly2(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, on_send_udp2)
	nbio.send_all_udp_poly3(net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, 3, on_send_udp3)

	on_read1 :: proc(one: int, read: int, err: nbio.FS_Error) {
		ev(t, one, 1)
	}
	on_read2 :: proc(one: int, two: int, read: int, err: nbio.FS_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_read3 :: proc(one: int, two: int, three: int, read: int, err: nbio.FS_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.read_at_poly (HANDLE, 0, nil, 1, on_read1)
	nbio.read_at_poly2(HANDLE, 0, nil, 1, 2, on_read2)
	nbio.read_at_poly3(HANDLE, 0, nil, 1, 2, 3, on_read3)

	nbio.read_at_all_poly (HANDLE, 0, nil, 1, on_read1)
	nbio.read_at_all_poly2(HANDLE, 0, nil, 1, 2, on_read2)
	nbio.read_at_all_poly3(HANDLE, 0, nil, 1, 2, 3, on_read3)

	on_write1 :: proc(one: int, written: int, err: nbio.FS_Error) {
		ev(t, one, 1)
	}
	on_write2 :: proc(one: int, two: int, written: int, err: nbio.FS_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_write3 :: proc(one: int, two: int, three: int, written: int, err: nbio.FS_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.write_at_poly (HANDLE, 0, nil, 1, on_write1)
	nbio.write_at_poly2(HANDLE, 0, nil, 1, 2, on_write2)
	nbio.write_at_poly3(HANDLE, 0, nil, 1, 2, 3, on_write3)

	nbio.write_at_all_poly (HANDLE, 0, nil, 1, on_write1)
	nbio.write_at_all_poly2(HANDLE, 0, nil, 1, 2, on_write2)
	nbio.write_at_all_poly3(HANDLE, 0, nil, 1, 2, 3, on_write3)

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

	nbio.poll_poly(TCP_SOCKET, .Read, false, 1, proc(one: int, res: nbio.Poll_Result) {
		ev(t, one, 1)
	})
	nbio.poll_poly2(TCP_SOCKET, .Read, false, 1, 2, proc(one: int, two: int, res: nbio.Poll_Result) {
		ev(t, one, 1)
		ev(t, two, 2)
	})
	nbio.poll_poly3(TCP_SOCKET, .Read, false, 1, 2, 3, proc(one: int, two: int, three: int, res: nbio.Poll_Result) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	})

	ev(t, nbio.run(), nil)
}

@(test)
read_entire_file_works :: proc(tt: ^testing.T) {
	if !check_support(tt) { return }
	defer nbio.destroy()

	@static t: ^testing.T
	t = tt

	fd, errno := nbio.open(#file)
	ev(t, errno, nil)

	nbio.read_entire_file(fd, 1, proc(one: int, buf: []byte, err: nbio.FS_Error) {
		ev(t, one, 1)
		ev(t, err, nil)
		ev(t, string(buf), #load(#file, string))
		delete(buf)
	})

	nbio.read_entire_file2(fd, 1, 2, proc(one: int, two: int, buf: []byte, err: nbio.FS_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, err, nil)
		ev(t, string(buf), #load(#file, string))
		delete(buf)
	})

	nbio.read_entire_file3(fd, 1, 2, 3, proc(one: int, two: int, three: int, buf: []byte, err: nbio.FS_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		ev(t, err, nil)
		ev(t, string(buf), #load(#file, string))
		delete(buf)
	})

	ev(t, nbio.run(), nil)

	nbio.close(fd)

	ev(t, nbio.run(), nil)
}
