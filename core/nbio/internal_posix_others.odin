#+build openbsd, netbsd
package nbio

import "core:sys/posix"
import "core:net"

// copy of proc in net package, just taking in an errno.
_dial_error :: proc(errno: posix.Errno) -> net.Dial_Error {
	return .Network_Unreachable
}

_tcp_send_error :: proc() -> net.TCP_Send_Error {
	return .Network_Unreachable
}

_udp_send_error :: proc() -> net.UDP_Send_Error {
	return .Network_Unreachable
}
