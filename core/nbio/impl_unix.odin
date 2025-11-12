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