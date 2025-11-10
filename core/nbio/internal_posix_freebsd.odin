#+private
package nbio

import "core:net"
import "core:sys/posix"
import "core:sys/freebsd"

// copy of proc in net package, just taking in an errno.
_dial_error :: proc(errno: posix.Errno) -> net.Dial_Error {
	return net._dial_error(freebsd.Errno(errno))
}

_tcp_send_error :: proc() -> net.TCP_Send_Error {
	return net._tcp_send_error(freebsd.Errno(posix.errno()))
}

_udp_send_error :: proc() -> net.UDP_Send_Error {
	return net._udp_send_error(freebsd.Errno(posix.errno()))
}
