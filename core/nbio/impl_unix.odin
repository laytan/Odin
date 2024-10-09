#+build darwin, netbsd, openbsd, freebsd, linux
#+private
package nbio

import "core:net"

_open_socket :: proc(
	_: ^IO,
	family: net.Address_Family,
	protocol: net.Socket_Protocol,
) -> (
	socket: net.Any_Socket,
	err: net.Network_Error,
) {
	socket  = net.create_socket(family, protocol) or_return

	err = _prepare_socket(socket)
	if err != nil { net.close(socket) }
	return
}

// TODO: public `prepare_handle` and `prepare_socket` to take in a handle/socket from some other source?
// (If that is possible on Windows).
_prepare_socket :: proc(socket: net.Any_Socket) -> net.Network_Error {
	net.set_option(socket, .Reuse_Address, true) or_return

	// TODO; benchmark this, even if faster it is prob not to be turned on
	// by default here, maybe by default for the server, but I don't think this
	// will be faster/more efficient.
	// net.set_option(socket, .TCP_Nodelay, true) or_return

	net.set_blocking(socket, false) or_return
	return nil
}
