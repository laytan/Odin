#+vet explicit-allocators
#+build !js
#+private
package http

import "base:runtime"

import "core:c"
import "core:http/dns"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:container/xar"

// TODO: proper error.
_client_init :: proc(c: ^Client, allocator := context.allocator) -> bool {
	c.allocator = allocator
	c.conns.allocator = allocator

	// PERF: this is "blocking"
	ns_err, hosts_err, ok := dns.init_sync(&c.dnsc, allocator)
	if ns_err != nil {
		log.warnf("DNS client init: name servers error: %v", ns_err)
	}
	if hosts_err != nil {
		log.warnf("DNS client init: hosts error: %v", hosts_err)
	}
	if ns_err != nil || hosts_err != nil || !ok {
		return false
	}

	return true
}

_client_destroy :: proc(_: ^nbio.Operation, c: ^Client, user_data: rawptr = nil, cb: proc(user_data: rawptr) = nil) {
	for ep, &conns in c.conns {
		it := xar.iterator(&conns)
		for conn in xar.iterate_by_ptr(&it) {
			switch conn.state {
			case .Idle:
				client_connection_destroy(c, conn)
			case .Issueing, .Closing: // wait
			case .Closed: // done
			}
		}
	}

	if len(c.conns) > 0 {
		nbio.next_tick_poly3(c, user_data, cb, _client_destroy)
		return
	}

	delete(c.conns)

	context.user_ptr = user_data
	dns.destroy(&c.dnsc, (rawptr)(cb), proc(cb: rawptr) {
		if cb != nil {
			(proc(user_data: rawptr))(cb)(context.user_ptr)
		}

		nbio.release_thread_event_loop()
	})
}

_incoming_response_destroy :: proc(res: Incoming_Response) {
	res := res

	allocator := res.body.allocator

	iter := headers_iterator(&res.headers)
	for k, v in headers_next(&iter) {
		delete(k, allocator)
		delete(v, allocator)
	}
	headers_destroy(&res.headers)
	delete(res.body)
}

_Client :: struct {
	allocator:   mem.Allocator,
	// TODO: ideally the dns client is able to be set by the user.
	// So you can run multiple clients on the same DNS client?
	dnsc:        dns.Client,
	// TODO: eviction after time etc.
	conns:       map[net.Endpoint]xar.Array(Client_Connection, 3),
	initialized: bool,
}

@(private="file")
Client_Connection :: struct {
	using issuer: Issuer_Connection,
	state: enum {
		Idle,
		Issueing,
		Closing,
		Closed,
	},
}

@(private="file")
client_connection_destroy :: proc(c: ^Client, conn: ^Client_Connection) {
	assert(conn.state != .Issueing, "closing while issueing a request")

	conn.state = .Closing

	if conn.ssl != nil {
		ssl_client.connection_destroy(ssl_client, conn.ssl)
	}

	nbio.close_poly2(conn.socket, c, conn, proc(op: ^nbio.Operation, c: ^Client, conn: ^Client_Connection) {
		if op.close.err != nil {
			log.warnf("failed closing connection: %v", op.close.err)
		}

		conn.state = .Closed

		conns, has_conns := &c.conns[conn.ep]
		assert(has_conns, "all connections should be in the connections map")

		// If all the connections to this endpoint are closed, clean it up.

		all_closed := true
		it := xar.iterator(conns)
		for conn in xar.iterate_by_ptr(&it) {
			if conn.state != .Closed {
				all_closed = false
				break
			}
		}

		if all_closed {
			xar.destroy(conns)
			delete_key(&c.conns, conn.ep)
		}

		scanner_destroy(&conn.scanner)
		headers_destroy(&conn.headers)
	})
}

_request :: proc(c: ^Client, req: Outgoing_Request) {
	if url_err := _validate_url(req.url); url_err != nil {
		_callback(req, nil, url_err)
		return
	}

	r := new(In_Flight, req.allocator)
	r.c = c
	r.r = req
	_client_request_on(r)
}

@(private="file")
In_Flight :: struct {
	using r: Outgoing_Request,
	c:       ^_Client,
	conn:    ^Client_Connection,
	res:     Incoming_Response,
}

@(private="file")
_client_request_on :: proc(r: ^In_Flight) {
	host_and_port    := url_parse(r.r.url).host
	host, _, port_ok := net.split_port(host_and_port)
	assert(port_ok)

	dns.resolve(&r.c.dnsc, host, r, on_dns_resolve, r.r.allocator)

	on_dns_resolve :: proc(r: rawptr, record: dns.Record, err: net.Network_Error) {
		r := (^In_Flight)(r)
		if err != nil {
			rerr := Request_Error.Unknown
			#partial switch net_err in err {
			case net.DNS_Error:
				switch net_err {
				case .None: unreachable() // shared-nil and checked nil.
				case .Invalid_Hostname_Error:
					assert(false, "invalid hostname when it should've been validated already")
				case .Invalid_Resolv_Config_Error, .Invalid_Hosts_Config_Error:
					rerr = .DNS_Config
				case .Server_Error, .Connection_Error, .System_Error:
					rerr = .DNS_Response_Invalid
				}
			case net.Resolve_Error:
				switch net_err {
				case .None: unreachable() // shared-nil and checked nil.
				case .Unable_To_Resolve:
					rerr = .DNS_Not_Resolved
				case .Allocation_Failure:
					rerr = .Allocation_Failure
				}
			case net.Create_Socket_Error:
				#partial switch net_err {
				case .Network_Unreachable:
					rerr = .Network
				case .Insufficient_Resources:
					rerr = .Allocation_Failure
				}
			case net.Set_Blocking_Error:
				#partial switch net_err {
				case .Network_Unreachable:
					rerr = .Network
				}
			case net.UDP_Send_Error:
				#partial switch net_err {
				case .Network_Unreachable:
					rerr = .Network
				case .Insufficient_Resources:
					rerr = .Allocation_Failure
				case .Timeout:
					rerr = .DNS_Timeout
				case .Host_Unreachable, .Connection_Refused:
					rerr = .DNS_Response_Invalid // Name server could not be reached.
				}
			case net.UDP_Recv_Error:
				#partial switch net_err {
				case .Network_Unreachable:
					rerr = .Network
				case .Insufficient_Resources:
					rerr = .Allocation_Failure
				case .Connection_Refused:
					rerr = .DNS_Response_Invalid
				case .Timeout:
					rerr = .DNS_Timeout
				}
			}

			callback_and_free(r, rerr)
			return
		}

		ep := net.Endpoint{ record.address, determine_target_port(r.r.url) }
		log.debugf("%v resolved to %v", r.r.url, ep)

		get_connection: {
			_, conns, first_connection, conns_alloc_err := map_entry(&r.c.conns, ep)
			if conns_alloc_err != nil {
				callback_and_free(r, .Allocation_Failure)
				return
			}
			conns.allocator = r.c.allocator

			it := xar.iterator(conns)
			for conn in xar.iterate_by_ptr(&it) {
				if conn.state == .Idle {
					r.conn = conn
					break get_connection
				}
			}

			append_conn_err: mem.Allocator_Error
			r.conn, append_conn_err = xar.append_and_get_ptr(conns, Client_Connection{
				allocator = r.c.allocator,
				ep = ep,
			})
			if append_conn_err != nil {
				if first_connection {
					delete_key(&r.c.conns, ep)
				}
				callback_and_free(r, .Allocation_Failure)
				return
			}
		}

		r.conn.state = .Issueing

		r.conn.curr_req = {
			body = r.body,
			headers = r.headers,
			url = r.url,
			method = r.method,
			user_data = r,
			cb = issued,
			allocator = r.allocator,
		}
		issue(r.conn)
	}

	issued :: proc(req: Issuer_Request, res: Issuer_Response, err: Request_Error) {
		r := (^In_Flight)(req.user_data)

		r.res.body.allocator = r.allocator
		if res.headers != nil {
			r.res.headers = res.headers^
		}
		r.res.status = res.status

		#partial switch err {
		case .Partial:
			append(&r.res.body, ..res.body)
			r.res.headers.readonly = true
			_callback(r, &r.res, .Partial)
			r.res.headers.readonly = false
		case .None:
			r.conn.body = {}
			res.headers^ = {}
			r.res.headers.readonly = true

			// TODO: what other statussus/special handling (like only on specific method, changing method, check spec).
			// TODO: have a max amount of redirects to follow.
			if !r.ignore_redirects && (r.res.status == .Found || r.res.status == .Moved_Permanently || r.res.status == .See_Other || r.res.status == .Temporary_Redirect || r.res.status == .Permanent_Redirect) {
				// Reset everything as if the request was made to the location.

				location, has_location := headers_get(r.res.headers, "Location")
				assert(has_location)

				log.infof("redirect %s -> %s", r.r.url, location)

				// TODO: don't mutate request.
				r.r.url = strings.clone(location, r.c.allocator) // TODO: leak

				r.conn.ep = {}
				r.conn = nil

				incoming_response_destroy(r.res)
				r.res = {}

				_client_request_on(r)
				break
			}

			// TODO: close connection if server indicates it, Connection: close header, HTTP 1.0, more?

			append(&r.res.body, ..res.body)
			r.conn.state = .Idle
			callback_and_free(r, nil)
		case:
			r.conn.state = .Idle
			// NOTE: closing connection because an error occurred on it.
			client_connection_destroy(r.c, r.conn)
			callback_and_free(r, err)
		}
	}

	callback_and_free :: proc(r: ^In_Flight, err: Request_Error) {
		assert(err != .Partial, "do not callback_and_free a partial response")
		_callback(r.r, &r.res, err)
		free(r, r.r.allocator)
	}

	determine_target_port :: proc(_url: string) -> int {
		url := url_parse(_url)
		_, port, port_ok := net.split_port(url.host)
		assert(port_ok) // checked before
		if port > 0 { return port }

		switch determine_scheme(_url, 0) {
		case .Https: return 443
		case .Http:  return 80
		case:        unreachable()
		}
	}
}

@(private="file")
_callback :: proc(req: Outgoing_Request, res: ^Incoming_Response, err: Request_Error) {
	if req.cb == nil && err != .Partial {
		if err != nil {
			log.errorf("%v %s: %v", req.method, req.url, err)
		}
		incoming_response_destroy(res^)
	} else {
		req.cb(req, res, err)
	}
}

@(private="file")
_validate_url :: proc(url: string) -> Request_Error {
	if len(url) == 0 {
		return .URL_Invalid
	}

	host_and_port := url_parse(url).host

	host, _, port_ok := net.split_port(host_and_port)
	if !port_ok {
		return .Port_Invalid
	}

	valid_host := net.validate_hostname(host)
	if !valid_host {
		return .URL_Invalid
	}

	return nil
}
