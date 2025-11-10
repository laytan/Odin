#+private
package nbio

import "core:net"
import "core:sys/posix"

// copy of proc in net package, just taking in an errno.
_dial_error :: proc(errno: posix.Errno) -> net.Dial_Error {
	#partial switch errno {
	case .ENOBUFS:
		return .Insufficient_Resources
	case .EAFNOSUPPORT, .EBADF, .EFAULT, .EINVAL, .ENOTSOCK, .EPROTOTYPE, .EADDRNOTAVAIL:
		return .Invalid_Argument
	case .EISCONN:
		return .Already_Connected
	case .EALREADY:
		return .Already_Connecting
	case .EADDRINUSE:
		return .Address_In_Use
	case .ENETDOWN:
		return .Network_Unreachable
	case .EHOSTUNREACH:
		return .Host_Unreachable
	case .ECONNREFUSED:
		return .Refused
	case .ECONNRESET:
		return .Reset
	case .ETIMEDOUT:
		return .Timeout
	case .EINPROGRESS:
		return .Would_Block
	case .EINTR:
		return .Interrupted
	case .EACCES:
		return .Broadcast_Not_Supported
	case:
		return .Unknown
	}
}

_tcp_send_error :: proc() -> net.TCP_Send_Error {
	return net._tcp_send_error()
}

_udp_send_error :: proc() -> net.UDP_Send_Error {
	return net._udp_send_error()
}
