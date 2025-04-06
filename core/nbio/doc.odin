/*
package nbio implements a non blocking IO abstraction layer over several platform specific APIs.

You can also have a look at the tests for more general usages.

Example:
	/*
	This example shows a simple TCP server that echos back anything it receives.

	Better error handling and closing/freeing connections are left for the reader.
	*/
	package main

	import "core:fmt"
	import "core:net"
	import "core:nbio"

	Echo_Server :: struct {
		sock:        net.TCP_Socket,
		connections: [dynamic]^Echo_Connection,
	}

	Echo_Connection :: struct {
		server:  ^Echo_Server,
		sock:    net.TCP_Socket,
		buf:     [50]byte,
	}

	main :: proc() {
		init_err := nbio.init()
		fmt.assertf(init_err == nil, "Could not initialize nbio: %v", init_err)
		defer nbio.destroy()

		server: Echo_Server
		defer delete(server.connections)

		sock, err := nbio.open_and_listen_tcp({net.IP4_Loopback, 8080})
		fmt.assertf(err == nil, "Error opening and listening on localhost:8080: %v", err)
		server.sock = sock

		nbio.accept_poly(sock, &server, echo_on_accept)

		// Start the event loop.
		rerr := nbio.run()
		fmt.assertf(rerr == nil, "Server stopped with error: %v", rerr)
	}

	echo_on_accept :: proc(server: ^Echo_Server, client: net.TCP_Socket, source: net.Endpoint, err: net.Accept_Error) {
		fmt.assertf(err == nil, "Error accepting a connection: %v", err)

		// Register a new accept for the next client.
		nbio.accept_poly(server.sock, server, echo_on_accept)

		c := new(Echo_Connection)
		c.server = server
		c.sock   = client
		append(&server.connections, c)

		nbio.recv_tcp_poly(client, c.buf[:], c, echo_on_recv)
	}

	echo_on_recv :: proc(c: ^Echo_Connection, received: int, err: net.TCP_Recv_Error) {
		fmt.assertf(err == nil, "Error receiving from client: %v", err)

		nbio.send_all_tcp_poly(c.sock, c.buf[:received], c, echo_on_sent)
	}

	echo_on_sent :: proc(c: ^Echo_Connection, sent: int, err: net.TCP_Send_Error) {
		fmt.assertf(err == nil, "Error sending to client: %v", err)

		// Accept the next message, to then ultimately echo back again.
		nbio.recv_tcp_poly(c.sock, c.buf[:], c, echo_on_recv)
	}
*/
package nbio
