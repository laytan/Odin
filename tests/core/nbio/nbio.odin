package tests_nbio

import "core:log"
import "core:nbio"
import "core:net"
import "core:testing"

ev :: testing.expect_value
e  :: testing.expect

@(require_results)
check_support :: proc(t: ^testing.T, loc := #caller_location) -> bool {
	err := nbio.init()
	if err == .Unsupported {
		log.warn("nbio is unsupported, skipping test", location=loc)
		return false
	}
	return ev(t, err, nil, loc)
}

open_next_available_local_port :: proc(t: ^testing.T, loc := #caller_location) -> (sock: net.TCP_Socket, ep: net.Endpoint) {
	err: net.Network_Error
	sock, err = nbio.open_and_listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		log.errorf("open_and_listen_tcp: %v", err, location=loc)
		return
	}

	ep, err = net.bound_endpoint(sock)
	if err != nil {
		log.errorf("bound_endpoint: %v", err, location=loc)
	}

	return
}

