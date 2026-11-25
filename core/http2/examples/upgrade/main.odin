// Low-level HTTP/1.1 protocol upgrades:
//   - `/echo`   (in-pool):  stays managed by `http.Server` to keep `Scanner`, quotas, `temp_allocator`,
//                           `http.send`, `response_defer`, and `connection_close` (like `core/websocket`).
//   - `/detach` (detached): removes the connection from `http.Server` via `connection_detach` to take
//                           direct ownership of the `nbio.TCP_Socket` and any unread `buffered` bytes.
//
// Run: odin run core/http2/examples/upgrade
//
// Try:
//   printf 'GET /echo HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: Upgrade\r\nUpgrade: line-echo\r\n\r\nhello\r\nworld\r\nquit\r\n' | nc 127.0.0.1 8080
//   printf 'GET /detach HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: Upgrade\r\nUpgrade: raw-echo\r\n\r\npipelined!\n' | nc 127.0.0.1 8080
package main

import "core:fmt"
import "core:nbio"
import "core:strings"
import "core:time"

import http "core:http2"

@(rodata)
UPGRADE_RECV_QUOTA := http.Quota{min = 60 * time.Second}

Echo_Conn :: struct {
	sock:     nbio.TCP_Socket,
	buffered: []byte,
	buf:      [4096]byte,
}

main :: proc() {
	r := http.make_router()
	defer http.router_destroy(r)
	http.route_get(&r, "/echo", handle_in_pool_upgrade)
	http.route_get(&r, "/detach", handle_detached_upgrade)

	fmt.println("Listening on http://127.0.0.1:8080")
	s := http.make_server(http.Server_Options{handlers = {http.router(&r)}})
	err := http.listen_and_serve(&s)
	fmt.assertf(err == nil, "server error: %v", err)
}

prepare_upgrade :: proc(ctx: ^http.Ctx, protocol: string) -> bool {
	upgrade, has_upgrade := http.get_header(ctx, "upgrade")
	if !http.headers_has_token(&ctx.req.headers, "connection", "upgrade") ||
	   !has_upgrade || !strings.equal_fold(upgrade, protocol) {
		ctx.res.status = .Upgrade_Required
		http.set_header(ctx, "Upgrade", protocol)
		http.respond_plain(ctx, fmt.tprintf("upgrade to %s required\n", protocol))
		return false
	}

	ctx.res.status = .Switching_Protocols
	http.set_header(ctx, "Connection", "upgrade")
	http.set_header(ctx, "Upgrade", protocol)
	return true
}

// --- 1. In-pool upgrade (keeps helpers and connection to the server) ---

handle_in_pool_upgrade :: proc(ctx: ^http.Ctx) {
	if !prepare_upgrade(ctx, "line-echo") {
		return
	}

	// send_ prefixed doesn't finish the response, this just sends the heading of the response.
	http.send_heading(ctx, on_upgraded)

	on_upgraded :: proc(ctx: ^http.Ctx, err: http.Send_Error) {
		if err != nil {
			return
		}

		// Low-level HTTP/1.1 connection hook for in-pool protocol takeover.
		c := http._connection_of_context(ctx)

		// Replace HTTP request/response quotas with protocol-appropriate limits (here: 60s idle recv, unlimited send).
		http.request_set_quota(&c.req, &UPGRADE_RECV_QUOTA)
		http.response_set_quota(&c.res, &http.UNLIMITED_QUOTA)

		fmt.printfln("[in-pool] client %v upgraded", c.socket)
		http.response_defer(ctx, proc(ctx: ^http.Ctx) {
			c := http._connection_of_context(ctx)
			fmt.printfln("[in-pool] client %v closed", c.socket)
		})

		scan_next_line(c)
	}

	scan_next_line :: proc(c: ^http.Connection) {
		http.progression_reset(&c.req.progress, UPGRADE_RECV_QUOTA)
		// `scan_temp_line` reads CRLF-delimited lines into `c.temp_arena` (automatically consuming any
		// pipelined bytes that already arrived after the HTTP upgrade headers).
		http.scan_temp_line(&c.scanner, on_line)
	}

	on_line :: proc(c: ^http.Connection, line: []byte) {
		if string(line) == "quit" {
			http.connection_close(c)
			return
		}

		crlf := transmute([]byte)string("\r\n")
		bufs := [][]byte{line, crlf} if len(line) > 0 else [][]byte{crlf}
		http.send(&c.ctx, bufs, on_sent)
	}

	on_sent :: proc(ctx: ^http.Ctx, err: http.Send_Error) {
		if err != nil {
			return
		}
		// Calling `free_all(context.temp_allocator)` after `http.send` finishes recycles `c.temp_arena`
		// blocks while automatically preserving any unread pipelined bytes still in `c.scanner`.
		free_all(context.temp_allocator)
		scan_next_line(http._connection_of_context(ctx))
	}
}

// --- 2. Detached upgrade (takes direct ownership of the socket + unread buffered bytes) ---

handle_detached_upgrade :: proc(ctx: ^http.Ctx) {
	if !prepare_upgrade(ctx, "raw-echo") {
		return
	}

	http.send_heading(ctx, on_upgraded)

	on_upgraded :: proc(ctx: ^http.Ctx, err: http.Send_Error) {
		if err != nil {
			return
		}

		// `connection_detach` removes the connection from the server pool and destroys its arenas, so `buffered`
		// must use a non-connection allocator and `ctx` must not be touched afterwards. The returned
		// `sock` stays associated with the event loop.
		sock, buffered, _ := http.connection_detach(ctx, context.allocator)

		ec := new(Echo_Conn)
		ec.sock = sock
		ec.buffered = buffered

		// Clients may pipeline raw protocol bytes right after the HTTP upgrade headers; flush any
		// unread bytes returned in `buffered` before reading more from `sock`.
		if len(ec.buffered) > 0 {
			nbio.send_poly(ec.sock, {ec.buffered}, ec, on_buffered_sent)
			return
		}

		start_recv(ec)
	}

	on_buffered_sent :: proc(op: ^nbio.Operation, ec: ^Echo_Conn) {
		delete(ec.buffered)
		ec.buffered = nil
		if op.send.err != nil {
			close_echo(ec)
			return
		}
		start_recv(ec)
	}

	start_recv :: proc(ec: ^Echo_Conn) {
		nbio.recv_poly(ec.sock, {ec.buf[:]}, ec, on_recv)

		on_recv :: proc(op: ^nbio.Operation, ec: ^Echo_Conn) {
			if op.recv.err != nil || op.recv.received == 0 {
				close_echo(ec)
				return
			}
			nbio.send_poly(ec.sock, {ec.buf[:op.recv.received]}, ec, on_sent)
		}

		on_sent :: proc(op: ^nbio.Operation, ec: ^Echo_Conn) {
			if op.send.err != nil {
				close_echo(ec)
				return
			}
			start_recv(ec)
		}
	}

	close_echo :: proc(ec: ^Echo_Conn) {
		delete(ec.buffered)
		nbio.close(ec.sock)
		free(ec)
	}
}

