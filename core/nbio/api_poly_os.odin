#+build !js
package nbio

import "base:intrinsics"

import "core:net"

close_poly :: proc(fd: Closable, p: $T, callback: $C/proc(p: T, err: FS_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _close(io(), fd, nil, proc(completion: rawptr, err: FS_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, err)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

close_poly2 :: proc(fd: Closable, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _close(io(), fd, nil, proc(completion: rawptr, err: FS_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, err)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

close_poly3 :: proc(fd: Closable, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _close(io(), fd, nil, proc(completion: rawptr, err: FS_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, err)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}

accept_poly :: proc(socket: net.TCP_Socket, p: $T, callback: $C/proc(p: T, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _accept(io(), socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, client, source, err)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

accept_poly2 :: proc(socket: net.TCP_Socket, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _accept(io(), socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, client, source, err)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

accept_poly3 :: proc(socket: net.TCP_Socket, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _accept(io(), socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, client, source, err)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}

connect_poly :: proc(endpoint: net.Endpoint, p: $T, callback: $C/proc(p: T, socket: net.TCP_Socket, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion, err := _connect(io(), endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, socket, err)
	})
	if err != nil {
		callback(p, {}, err)
		return completion
	}

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

connect_poly2 :: proc(endpoint: net.Endpoint, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, socket: net.TCP_Socket, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion, err := _connect(io(), endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, socket, err)
	})
	if err != nil {
		callback(p, p2, {}, err)
		return completion
	}

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

connect_poly3 :: proc(endpoint: net.Endpoint, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, socket: net.TCP_Socket, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS  {
	completion, err := _connect(io(), endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, socket, err)
	})
	if err != nil {
		callback(p, p2, p3, {}, err)
		return completion
	}

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}

_recv_tcp_poly :: proc(socket: net.TCP_Socket, buf: []byte, all: bool, p: $T, callback: $C/proc(p: T, received: int, err: net.TCP_Recv_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _recv(io(), socket, buf, nil, On_Recv_TCP(proc(completion: rawptr, received: int, err: net.TCP_Recv_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, received, err)
	}))

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

_recv_tcp_poly2 :: proc(socket: net.TCP_Socket, buf: []byte, all: bool, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, err: net.TCP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _recv(io(), socket, buf, nil, On_Recv_TCP(proc(completion: rawptr, received: int, err: net.TCP_Recv_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, received, err)
	}))

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

_recv_tcp_poly3 :: proc(socket: net.TCP_Socket, buf: []byte, all: bool, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, err: net.TCP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _recv(io(), socket, buf, nil, On_Recv_TCP(proc(completion: rawptr, received: int, err: net.TCP_Recv_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, received, err)
	}))

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}

_recv_udp_poly :: proc(socket: net.UDP_Socket, buf: []byte, all: bool, p: $T, callback: $C/proc(p: T, received: int, client: net.Endpoint, err: net.UDP_Recv_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _recv(io(), socket, buf, nil, On_Recv_UDP(proc(completion: rawptr, received: int, client: net.Endpoint, err: net.UDP_Recv_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, received, client, err)
	}))

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

_recv_udp_poly2 :: proc(socket: net.UDP_Socket, buf: []byte, all: bool, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, client: net.Endpoint, err: net.UDP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _recv(io(), socket, buf, nil, On_Recv_UDP(proc(completion: rawptr, received: int, client: net.Endpoint, err: net.UDP_Recv_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, received, client, err)
	}))

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

_recv_udp_poly3 :: proc(socket: net.UDP_Socket, buf: []byte, all: bool, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, client: net.Endpoint, err: net.UDP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _recv(io(), socket, buf, nil, On_Recv_UDP(proc(completion: rawptr, received: int, client: net.Endpoint, err: net.UDP_Recv_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, received, client, err)
	}))

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}

recv_tcp_poly :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, received: int, err: net.TCP_Recv_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_tcp_poly(socket, buf, false, p, callback)
}

recv_tcp_poly2 :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, err: net.TCP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_tcp_poly2(socket, buf, false, p, p2, callback)
}

recv_tcp_poly3 :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, err: net.TCP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_tcp_poly3(socket, buf, false, p, p2, p3, callback)
}

recv_all_tcp_poly :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, received: int, err: net.TCP_Recv_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_tcp_poly(socket, buf, true, p, callback)
}

recv_all_tcp_poly2 :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, err: net.TCP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_tcp_poly2(socket, buf, true, p, p2, callback)
}

recv_all_tcp_poly3 :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, err: net.TCP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_tcp_poly3(socket, buf, true, p, p2, p3, callback)
}

recv_udp_poly :: #force_inline proc(socket: net.UDP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, received: int, client: net.Endpoint, err: net.UDP_Recv_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_udp_poly(socket, buf, false, p, callback)
}

recv_udp_poly2 :: #force_inline proc(socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, client: net.Endpoint, err: net.UDP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_udp_poly2(socket, buf, false, p, p2, callback)
}

recv_udp_poly3 :: #force_inline proc(socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, client: net.Endpoint, err: net.UDP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_udp_poly3(socket, buf, false, p, p2, p3, callback)
}

recv_all_udp_poly :: #force_inline proc(socket: net.UDP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, received: int, client: net.Endpoint, err: net.UDP_Recv_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_udp_poly(socket, buf, true, p, callback)
}

recv_all_udp_poly2 :: #force_inline proc(socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, client: net.Endpoint, err: net.UDP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_udp_poly2(socket, buf, true, p, p2, callback)
}

recv_all_udp_poly3 :: #force_inline proc(socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, client: net.Endpoint, err: net.UDP_Recv_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _recv_udp_poly3(socket, buf, true, p, p2, p3, callback)
}

_send_tcp_poly :: proc(socket: net.TCP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.TCP_Send_Error), all := false) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _send(io(), socket, buf, nil, On_Sent_TCP(proc(completion: rawptr, sent: int, err: net.TCP_Send_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, sent, err)
	}), nil, all)

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

_send_tcp_poly2 :: proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.TCP_Send_Error), all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _send(io(), socket, buf, nil, On_Sent_TCP(proc(completion: rawptr, sent: int, err: net.TCP_Send_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, sent, err)
	}), nil, all)

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

_send_tcp_poly3 :: proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.TCP_Send_Error), all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _send(io(), socket, buf, nil, On_Sent_TCP(proc(completion: rawptr, sent: int, err: net.TCP_Send_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, sent, err)
	}), nil, all)

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}

_send_udp_poly :: proc(socket: net.UDP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.UDP_Send_Error), endpoint: net.Endpoint, all := false) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _send(io(), socket, buf, nil, On_Sent_UDP(proc(completion: rawptr, sent: int, err: net.UDP_Send_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, sent, err)
	}), endpoint, all)

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

_send_udp_poly2 :: proc(socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.UDP_Send_Error), endpoint: net.Endpoint, all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _send(io(), socket, buf, nil, On_Sent_UDP(proc(completion: rawptr, sent: int, err: net.UDP_Send_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, sent, err)
	}), endpoint, all)

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

_send_udp_poly3 :: proc(socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.UDP_Send_Error), endpoint: net.Endpoint, all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _send(io(), socket, buf, nil, On_Sent_UDP(proc(completion: rawptr, sent: int, err: net.UDP_Send_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, sent, err)
	}), endpoint, all)

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}

send_tcp_poly :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.TCP_Send_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_tcp_poly(socket, buf, p, callback)
}

send_tcp_poly2 :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.TCP_Send_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_tcp_poly2(socket, buf, p, p2, callback)
}

send_tcp_poly3 :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.TCP_Send_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_tcp_poly3(socket, buf, p, p2, p3, callback)
}

send_udp_poly :: #force_inline proc(endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.UDP_Send_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_udp_poly(socket, buf, p, callback, endpoint)
}

send_udp_poly2 :: #force_inline proc(endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.UDP_Send_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_udp_poly2(socket, buf, p, p2, callback, endpoint)
}

send_udp_poly3 :: #force_inline proc(endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.UDP_Send_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_udp_poly3(socket, buf, p, p2, p3, callback, endpoint)
}

send_all_tcp_poly :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.TCP_Send_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_tcp_poly(socket, buf, p, callback, all = true)
}

send_all_tcp_poly2 :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.TCP_Send_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_tcp_poly2(socket, buf, p, p2, callback, all = true)
}

send_all_tcp_poly3 :: #force_inline proc(socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.TCP_Send_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_tcp_poly3(socket, buf, p, p2, p3, callback, all = true)
}

send_all_udp_poly :: #force_inline proc(endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.UDP_Send_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_udp_poly(socket, buf, p, callback, endpoint, all = true)
}

send_all_udp_poly2 :: #force_inline proc(endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.UDP_Send_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_udp_poly2(socket, buf, p, p2, callback, endpoint, all = true)
}

send_all_udp_poly3 :: #force_inline proc(endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.UDP_Send_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _send_udp_poly3(socket, buf, p, p2, p3, callback, endpoint, all = true)
}

/// Read Internal

_read_poly :: proc(fd: Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: FS_Error), all := false) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _read(io(), fd, offset, buf, nil, proc(completion: rawptr, read: int, err: FS_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, read, err)
	}, all)

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

_read_poly2 :: proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: FS_Error), all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _read(io(), fd, offset, buf, nil, proc(completion: rawptr, read: int, err: FS_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, read, err)
	}, all)

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

_read_poly3 :: proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: FS_Error), all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _read(io(), fd, offset, buf, nil, proc(completion: rawptr, read: int, err: FS_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, read, err)
	}, all)

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}

read_at_poly :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: FS_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _read_poly(fd, offset, buf, p, callback)
}

read_at_poly2 :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _read_poly2(fd, offset, buf, p, p2, callback)
}

read_at_poly3 :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _read_poly3(fd, offset, buf, p, p2, p3, callback)
}

read_at_all_poly :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: FS_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _read_poly(fd, offset, buf, p, callback, all = true)
}

read_at_all_poly2 :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _read_poly2(fd, offset, buf, p, p2, callback, all = true)
}

read_at_all_poly3 :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _read_poly3(fd, offset, buf, p, p2, p3, callback, all = true)
}

_write_poly :: proc(fd: Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: FS_Error), all := false) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _write(io(), fd, offset, buf, nil, proc(completion: rawptr, written: int, err: FS_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, written, err)
	}, all)

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

_write_poly2 :: proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: FS_Error), all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _write(io(), fd, offset, buf, nil, proc(completion: rawptr, written: int, err: FS_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, written, err)
	}, all)

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

_write_poly3 :: proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: FS_Error), all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _write(io(), fd, offset, buf, nil, proc(completion: rawptr, written: int, err: FS_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, written, err)
	}, all)

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}

write_at_poly :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: FS_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _write_poly(fd, offset, buf, p, callback)
}

write_at_poly2 :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _write_poly2(fd, offset, buf, p, p2, callback)
}

write_at_poly3 :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _write_poly3(fd, offset, buf, p, p2, p3, callback)
}

write_at_all_poly :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: FS_Error)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _write_poly(fd, offset, buf, p, callback, all = true)
}

write_at_all_poly2 :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _write_poly2(fd, offset, buf, p, p2, callback, all = true)
}

write_at_all_poly3 :: #force_inline proc(fd: Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: FS_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	return _write_poly3(fd, offset, buf, p, p2, p3, callback, all = true)
}

poll_poly :: proc(fd: Handle, event: Poll_Event, multi: bool, p: $T, callback: $C/proc(p: T, event: Poll_Event)) -> ^Completion
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _poll(io(), fd, event, multi, nil, proc(completion: rawptr, event: Poll_Event) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C)(rawptr(ptr)))
		p   := unall((^T)(rawptr(ptr + size_of(C))))
		cb(p, event)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C)(rawptr(ptr)),                     callback)
	unals((^T)(rawptr(ptr + size_of(callback))), p)

	completion.user_data = completion
	return completion
}

poll_poly2 :: proc(fd: Handle, event: Poll_Event, multi: bool, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, event: Poll_Event)) -> ^Completion
	where size_of(T) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _poll(io(), fd, event, multi, nil, proc(completion: rawptr, event: Poll_Event) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		cb(p, p2, event)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                  callback)
	unals((^T) (rawptr(ptr + size_of(callback))),              p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))), p2)

	completion.user_data = completion
	return completion
}

poll_poly3 :: proc(fd: Handle, event: Poll_Event, multi: bool, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, event: Poll_Event)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	completion := _poll(io(), fd, event, multi, nil, proc(completion: rawptr, event: Poll_Event) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := unall((^C) (rawptr(ptr)))
		p   := unall((^T) (rawptr(ptr + size_of(C))))
		p2  := unall((^T2)(rawptr(ptr + size_of(C) + size_of(T))))
		p3  := unall((^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2))))
		cb(p, p2, p3, event)
	})

	ptr := uintptr(&completion.user_args)

	unals((^C) (rawptr(ptr)),                                                callback)
	unals((^T) (rawptr(ptr + size_of(callback))),                            p)
	unals((^T2)(rawptr(ptr + size_of(callback) + size_of(p))),               p2)
	unals((^T3)(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2))), p3)

	completion.user_data = completion
	return completion
}
