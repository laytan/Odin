package http

import "core:mem"
import "core:net"

@(private)
ssl_client: SSL_Client 

// TODO: put on http client, no need for a global.
set_ssl_client :: proc(ssl: SSL_Client) {
	ssl_client = ssl
}

SSL_Connection :: distinct rawptr

SSL_Result :: enum {
	None,
	Want_Read,
	Want_Write,
	Shutdown,
	Fatal,
}

SSL_Capability :: enum {
	// If kernel level TLS is enabled for the connection.
	// When this is true `send` will not be called on this connection, sending will be done through `nbio` instead.
	// It also enables the use of `sendfile` for efficiently sending files.
	KTLS,
}
SSL_Capabilities :: bit_set[SSL_Capability]

SSL_Client :: struct {
	user_data:          rawptr,
	client_destroy:     proc(client: SSL_Client),
	connection_create:  proc(client: SSL_Client, socket: net.TCP_Socket, host: string, allocator: mem.Allocator) -> SSL_Connection,
	connection_destroy: proc(client: SSL_Client, connection: SSL_Connection),
	connect:            proc(c: SSL_Connection) -> (SSL_Result, SSL_Capabilities),
	send:               proc(c: SSL_Connection, data: [][]byte) -> (int, SSL_Result),
	recv:               proc(c: SSL_Connection, buf: []byte) -> (int, SSL_Result),
}
