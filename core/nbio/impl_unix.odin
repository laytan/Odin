#+build darwin, freebsd, linux, openbsd, netbsd
#+private
package nbio

import "core:net"

_create_socket :: proc(
	_: ^Event_Loop,
	family: net.Address_Family,
	protocol: net.Socket_Protocol,
) -> (
	socket: Any_Socket,
	err: net.Network_Error,
) {
	socket = net.create_socket(family, protocol) or_return
	defer if err != nil { net.close(socket) }
	net.set_blocking(socket, false) or_return
	return
}

_listen_tcp :: proc(
	l: ^Event_Loop,
	endpoint: net.Endpoint,
	backlog := 1000,
) -> (
	socket: TCP_Socket,
	err: net.Network_Error,
) {
	any_socket := _create_socket(l, .IP4, .TCP) or_return
	defer if err != nil { net.close(any_socket) }

	net.set_option(any_socket, .Reuse_Address, true)

	net.bind(any_socket, endpoint) or_return

	socket = any_socket.(TCP_Socket)
	_listen(socket, backlog) or_return
	return
}
