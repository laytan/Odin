// A fully non-blocking DNS client with TTL caching.
#+vet explicit-allocators
package dns

import "base:runtime"

import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:time"
import "core:os"

// Time we wait for a response from a DNS server in nanoseconds.
DNS_SERVER_TIMEOUT :: #config(DNS_CLIENT_NAMESERVER_TIMEOUT, time.Second)

// Max amount of seconds a DNS response is cached regardless of the TTL it suggests.
MAX_TTL_SECONDS :: #config(DNS_CLIENT_MAX_TTL, 60*60)

Init_Error :: enum {
	None,
	No_Path,
	Failed_Open,
	Failed_Read,
	Unsupported,
}

_INIT_ERROR_LOADING :: Init_Error(-1)

On_Init :: #type proc(c: ^Client, user: rawptr, name_servers_err: Init_Error, hosts_err: Init_Error)

// WARNING: Consider all these fields private.
Client :: struct {
	allocator: mem.Allocator,

	cache: map[string]Cache_Entry,

	// Hosts/Name servers configuration.
	name_servers:     []net.Endpoint,
	name_servers_err: Init_Error,

	hosts:            []net.DNS_Host_Entry,
	hosts_err:        Init_Error,

	init_cb: On_Init,
	init_ud: rawptr,

	init_state: enum {
		Uninitialized,
		Initializing,
		Done,
	},
}

Record :: struct {
	address:  net.Address,
	ttl_secs: u32,
}

@(private)
Cache_Entry :: struct {
	record:    Record,
	resolving: bool,
	err:       net.Network_Error,
	callbacks: struct {
		inline:   Callback,
		overflow: [dynamic]Callback,
	},
	evictor:   ^nbio.Operation,
}

@(private)
Callback :: struct {
	cb:  On_Resolve,
	ud:  rawptr,
	ctx: runtime.Context,
}

init :: proc(c: ^Client, user_data: rawptr, on_init: On_Init, allocator := context.allocator) {
	assert(c.init_state == .Uninitialized, "already initializing/initialized")

	c.allocator = allocator
	c.cache.allocator = allocator

	c.init_cb = on_init
	c.init_ud = user_data

	c.name_servers_err = _INIT_ERROR_LOADING
	c.hosts_err        = _INIT_ERROR_LOADING

	c.init_state = .Initializing

	if err := nbio.acquire_thread_event_loop(); err != nil {
		if err == .Unsupported {
			on_init(c, user_data, .Unsupported, .Unsupported)
			return
		}
		panic("unexpected error from nbio.init")
	}

	net.init_dns_configuration()
	load_name_servers(c)
	load_hosts(c)
}

init_sync :: proc(c: ^Client, allocator := context.allocator) -> (name_servers_err: Init_Error, hosts_err: Init_Error, ok: bool) {
	init(c, nil, proc(c: ^Client, user: rawptr, name_servers_err: Init_Error, hosts_err: Init_Error) {}, allocator)
	return wait_for_init(c)
}

wait_for_init :: proc(c: ^Client) -> (name_servers_err: Init_Error, hosts_err: Init_Error, ok: bool) {
	assert(c.name_servers_err == _INIT_ERROR_LOADING || c.hosts_err == _INIT_ERROR_LOADING, "not initializing")
	for {
		errno := nbio.tick()
		if errno != nil {
			return c.name_servers_err, c.hosts_err, false
		}

		if c.name_servers_err != _INIT_ERROR_LOADING && c.hosts_err != _INIT_ERROR_LOADING {
			return c.name_servers_err, c.hosts_err, true
		}
	}
}

// Waits until all requests are done and frees all related resources.
destroy :: proc {
	destroy_cb,
	destroy_no_cb,
}

destroy_no_cb :: proc(c: ^Client) {
	destroy_cb(c, nil, proc(_: rawptr) {})
}

destroy_cb :: proc(c: ^Client, user: rawptr, cb: proc(user: rawptr)) {
	_destroy_cb :: proc(_: ^nbio.Operation, c: ^Client, user: rawptr, cb: proc(user: rawptr)) {
		cache_clear(c)

		// Try to clear again next tick, we don't want to interrupt in progress requests.
		if len(c.cache) > 0 {
			nbio.next_tick_poly3(c, user, cb, _destroy_cb)
		} else {
			delete(c.cache)
			delete(c.name_servers, c.allocator)
			for h in c.hosts {
				delete(h.name, c.allocator)
			}
			delete(c.hosts, c.allocator)
			nbio.release_thread_event_loop()
			cb(user)
		}
	}
	_destroy_cb(nil, c, user, cb)
}

// Removes any cache entries that aren't currently being resolved.
cache_clear :: proc(c: ^Client) {
	for hostname, entry in c.cache {
		if entry.resolving { continue }
		log.debugf("DNS of %q has been evicted", hostname)

		delete(hostname, c.allocator)
		delete_key(&c.cache, hostname)
		nbio.remove(entry.evictor)
	}
}

// Removes the entry (if it exists) for the given hostname from the DNS cache.
cache_evict :: proc(c: ^Client, hostname: string) {
	if entry, ok := c.cache[hostname]; ok {
		assert(!entry.resolving)
		log.debugf("DNS of %q has been evicted", hostname)
		delete_key(&c.cache, hostname)
		delete(hostname, c.allocator)
		nbio.remove(entry.evictor)
	}
}

// Removes entries so that the cache has at most `max_entries` in it.
// NOTE: this is done "psuedo-random".
cache_shrink :: proc(c: ^Client, max_entries: int) {
	to_remove := max(0, len(c.cache) - max_entries)
	for hostname, entry in c.cache {
		if to_remove <= 0 {
			break
		}

		if entry.resolving {
			continue
		}

		delete_key(&c.cache, hostname)
		delete(hostname, c.allocator)
		nbio.remove(entry.evictor)

		to_remove -= 1
	}
}

On_Resolve :: #type proc(user: rawptr, record: Record, err: net.Network_Error)

@(private)
Request :: struct {
	allocator:   runtime.Allocator,
	hostname:    string,
	family:      Address_Family,
	socket:      net.UDP_Socket,
	err:         net.Network_Error,
	client:      ^Client,
	name_server: int,
	packet_len:  int,
	packet:      [net.DNS_PACKET_MIN_LEN]byte,
	response:    [4096]byte,
}

Address_Family :: enum {
	None,
	IP4,
	IP6,
}

/*
Resolve the given hostname to an IP4 or IP6 address.

The given `hostname` string is copied internally and can thus be temporary.

On completion, the request/response is cached for further use, and a timeout is added to the
event loop to evict the record after the returned time to live.

`request_allocator` is used for allocations with a lifetime of the request/resolve being in progress.

General Process:
In the cache?
  Yes - Still resolving?
    Yes - Add callback to list of callbacks that are called after resolving
    No  - Call the callback with DNS record from the cache
  No - Check for matches in the user's hosts file (`/etc/hosts` for example), is it there?
    Yes - Call callback with match
    No  - Start resolving, create in progress cache entry send IP4 request to the first name server
          retrieved from the user's resolv file (`/etc/resolv.conf` for example)
          Each name server is given a timeout of `DNS_SERVER_TIMEOUT` to respond,
          if it doesn't respond or if it fails (error or no result) the next name server is tried.
          If all name servers haven't returned any result for IP4, the same loop over all name servers
          is started for IP6. Did any name server respond with an address?
            Yes - Complete the cache entry and call all queued callbacks,
                  and add a timeout for the returned time to live (with a `MAX_TTL_SECONDS` maximum)
                  seconds to the event loop which on completion evicts the record from the cache.
            No  - Complete the cache entry with an error and call all queued callbacks,
                  and add a timeout for 1 minute for the record to be evicted from the cache.

Errors:
 - net.DNS_Error.Invalid_Hostname_Error      - Given hostname is empty, too long, or otherwise invalid according to RFC 952 & RFC 1123
 - net.DNS_Error.Invalid_Resolv_Config_Error - configuration has 0 name servers
 - net.Resolve_Error.Allocation_Failure      - Appending to callbacks, cloning hostname, or allocating request state failed
 - net.Create_Socket_Error                   - Error creating a socket
 - net.Set_Blocking_Error                    - Error setting created socket to non-blocking mode
 - net.UDP_Send_Error                        - Error sending packet to name server (NOTE: if there are more name servers they are tried first)
 - net.UDP_Recv_Error                        - Error receiving response from name server (NOTE: if there are more name servers they are tried first)
 - net.DNS_Error.Server_Error                - Result from name server was corrupt/invalid (NOTE: if there are more name servers they are tried first)
 - net.Resolve_Error.Unable_To_Resolve       - All configured name servers were tried and none returned a valid DNS record
*/
resolve :: proc(c: ^Client, hostname: string, user: rawptr, cb: On_Resolve, request_allocator := context.allocator) {
	assert(c != nil)
	hostname, _, _ := net.split_port(hostname)

	if !net.validate_hostname(hostname) {
		cb(user, {}, .Invalid_Hostname_Error)
		return
	}


	switch c.init_state {
	case .Uninitialized:
		_, _, io_ok := init_sync(c, context.allocator)
		assert(io_ok, "nbio unsupported or allocation failure")
	case .Initializing:
		_, _, io_ok := wait_for_init(c)
		assert(io_ok, "nbio unsupported or allocation failure")
	case .Done:
	}

	if c.name_servers_err != nil {
		cb(user, {}, .Invalid_Resolv_Config_Error)
		return
	}

	for host in c.hosts {
		if host.name != hostname {
			continue
		}

		switch addr in host.addr {
		case net.IP4_Address:
			cb(user, { address = host.addr.(net.IP4_Address) }, nil)
			return
		case net.IP6_Address:
			cb(user, { address = host.addr.(net.IP6_Address) }, nil)
			return
		}
	}

	if len(c.name_servers) == 0 {
		cb(user, {}, .Invalid_Resolv_Config_Error)
		return
	}

	cache_hostname, cached, new_entry, cache_err := map_entry(&c.cache, hostname)
	if cache_err == nil && !new_entry {
		if cached.resolving {
			_, append_cb_err := append(&cached.callbacks.overflow, Callback{cb, user, context})
			if append_cb_err != nil {
				cb(user, {}, net.Resolve_Error.Allocation_Failure)
			}

		} else {
			cb(user, cached.record, cached.err)
		}
		return
	}

	host, clone_host_err := strings.clone(hostname, c.allocator)
	if clone_host_err != nil {
		delete_key(&c.cache, hostname)
		cb(user, {}, net.Resolve_Error.Allocation_Failure)
		return
	}

	req, req_alloc_err := new(Request, request_allocator)
	if req_alloc_err != nil {
		delete_key(&c.cache, host)
		delete(host, c.allocator)
		cb(user, {}, net.Resolve_Error.Allocation_Failure)
		return
	}

	req.allocator   = request_allocator
	req.hostname    = host
	req.family      = .IP6
	req.client      = c
	req.name_server = -1

	if cache_err == nil {
		cache_hostname^ = host

		cached.resolving = true
		cached.callbacks.inline = {cb, user, context}
		cached.callbacks.overflow.allocator = request_allocator
	}

	packet, make_dns_packet_err := net.make_dns_packet(req.packet[:], 0, hostname, .IP6)
	assert(make_dns_packet_err == nil, "hostname already validated so should be valid here")
	req.packet_len = len(packet)

	next(req, nil)

	next :: proc(req: ^Request, err: net.Network_Error) {
		if err != nil {
			req.err = err
		}

		if req.socket != {} {
			nbio.close(req.socket)
			req.socket = {}
		}

		req.name_server += 1
		if req.name_server >= len(req.client.name_servers) {
			#partial switch req.family {
			case .IP6:
				req.family = .IP4
				req.name_server = -1

				packet, make_dns_packet_err := net.make_dns_packet(req.packet[:], 0, req.hostname, .IP4)
				assert(make_dns_packet_err == nil) // making IP6 succeeded so IP4 should also
				req.packet_len = len(packet)

				// NOTE: originally did this, but it's not actually correct.
				// change_dns_packet_family(req.packet[:req.packet_len], .DNS_TYPE_A)

				next(req, nil)
			case .IP4:
				entry := &req.client.cache[req.hostname]
				assert(entry != nil, "in progress DNS resolve should always be in cache")

				entry.err = .Unable_To_Resolve if req.err == nil else req.err
				entry.resolving = false

				do_callbacks(entry)
				// NOTE: cache the error, user can `cache_evict` to remove and try the resolve again.
				nbio.timeout_poly2(time.Minute, req.client, req.hostname, evict_record)
				free(req, req.allocator)
			case:
				unreachable()
			}
			return
		}

		ns := req.client.name_servers[req.name_server]
		family := net.family_from_address(ns.address)

		sock, oerr := nbio.create_socket(family, .UDP)
		if oerr != nil {
			next(req, oerr)
			return
		}
		req.socket = sock.(net.UDP_Socket)

		nbio.send_poly(req.socket, {req.packet[:req.packet_len]}, req, on_sent, ns, timeout=DNS_SERVER_TIMEOUT)
	}

	on_record :: proc(req: ^Request, rec: Record) {
		nbio.close(req.socket)

		entry := &req.client.cache[req.hostname]
		assert(entry != nil, "in progress DNS resolve should always be in cache")
		entry.resolving = false
		entry.record = rec

		expires := time.Second*time.Duration(clamp(rec.ttl_secs, 0, MAX_TTL_SECONDS))
		entry.evictor = nbio.timeout_poly2(expires, req.client, req.hostname, evict_record)

		free(req, req.allocator)
		do_callbacks(entry)
	}

	evict_record :: proc(op: ^nbio.Operation, c: ^Client, hostname: string) {
		assert(op != nil, "use cache_evict")
		if entry, ok := c.cache[hostname]; ok {
			assert(!entry.resolving)
			assert(entry.evictor == op)
			log.debugf("DNS TTL of %vs from %q has expired", entry.record.ttl_secs, hostname)
			delete_key(&c.cache, hostname)
			delete(hostname, c.allocator)
		}
	}

	do_callbacks :: proc(entry: ^Cache_Entry) {
		{
			context = entry.callbacks.inline.ctx
			entry.callbacks.inline.cb(entry.callbacks.inline.ud, entry.record, entry.err)
			for cb in entry.callbacks.overflow {
				context = cb.ctx
				cb.cb(cb.ud, entry.record, entry.err)
			}
		}
		delete(entry.callbacks.overflow)
		entry.callbacks = {}
	}

	on_sent :: proc(op: ^nbio.Operation, req: ^Request) {
		if op.send.err != nil {
			next(req, op.send.err.(net.UDP_Send_Error))
			return
		}

		nbio.recv_poly(req.socket, {req.response[:]}, req, on_recv, timeout=DNS_SERVER_TIMEOUT)
	}

	on_recv :: proc(op: ^nbio.Operation, req: ^Request) {
		if op.recv.err != nil {
			next(req, op.recv.err.(net.UDP_Recv_Error))
			return
		}

		if op.recv.received == 0 {
			next(req, net.UDP_Recv_Error.Connection_Refused)
			return
		}

		// TODO: could we have gotten a partial response back and need to read more?
		response := req.response[:op.recv.received]

		HEADER_SIZE_BYTES :: 12
		if len(response) < HEADER_SIZE_BYTES {
			next(req, .Server_Error)
			return
		}

		dns_hdr_chunks := mem.slice_data_cast([]u16be, response[:HEADER_SIZE_BYTES])
		hdr := net.unpack_dns_header(dns_hdr_chunks[0], dns_hdr_chunks[1])
		if !hdr.is_response {
			next(req, .Server_Error)
			return
		}

		// NOTE: we hardcode an ID of 0 right now.
		if hdr.id != 0 {
			next(req, .Server_Error)
			return
		}

		question_count := int(dns_hdr_chunks[2])
		if question_count != 1 {
			next(req, .Server_Error)
			return
		}

		answer_count     := int(dns_hdr_chunks[3])
		authority_count  := int(dns_hdr_chunks[4])
		additional_count := int(dns_hdr_chunks[5])

		cur_idx := HEADER_SIZE_BYTES

		dq_sz :: 4
		hn_sz, hs_ok := net.skip_hostname(response, cur_idx)
		if !hs_ok {
			next(req, .Server_Error)
			return
		}
		cur_idx += hn_sz + dq_sz

		for _ in 0..<answer_count+authority_count+additional_count {
			if cur_idx >= len(response) {
				continue
			}

			family, rec, ok := parse_record(response, &cur_idx)
			if !ok {
				next(req, .Server_Error)
				return
			}

			if family == req.family {
				on_record(req, rec)
				return
			}
		}

		next(req, nil)
	}
}

@(private)
load_name_servers_done :: proc(c: ^Client, err: Init_Error, msg: string = "", args: ..any) {
	if msg != "" {
		log.warnf(msg, ..args)
	}

	c.name_servers_err = err

	if c.hosts_err != _INIT_ERROR_LOADING && c.init_cb != nil {
		c.init_state = .Done
		c.init_cb(c, c.init_ud, c.name_servers_err, c.hosts_err)
	}
}

@(private)
load_hosts_done :: proc(c: ^Client, err: Init_Error, msg: string = "", args: ..any) {
	if msg != "" {
		log.warnf(msg, ..args)
	}

	c.hosts_err = err

	if c.name_servers_err != _INIT_ERROR_LOADING && c.init_cb != nil {
		c.init_state = .Done
		c.init_cb(c, c.init_ud, c.name_servers_err, c.hosts_err)
	}
}

// Loads the name servers from the OS, this is called implicitly during `init`.
@(private)
load_name_servers :: proc(c: ^Client) {
	assert(c.name_servers_err == _INIT_ERROR_LOADING)
	_load_name_servers(c)
}

// Loads the hosts file from the OS, this is implicitly called during `init`.
@(private)
load_hosts :: proc(c: ^Client) {
	assert(c.hosts_err == _INIT_ERROR_LOADING)

	hosts_file := net.dns_configuration.hosts_file
	if hosts_file == "" {
		load_hosts_done(c, .No_Path, "the `net.DEFAULT_DNS_CONFIGURATION` does not contain a filepath to find the hosts file")
		return
	}

	log.debugf("reading hosts file at %q", hosts_file)

	fd, err := nbio.open_sync(hosts_file)
	if err != nil {
		load_hosts_done(c, .Failed_Open, "the hosts file at %q could not be opened due to errno: %v", hosts_file, err)
		return
	}

	on_hosts_content :: proc(op: ^nbio.Operation, c: ^Client, file: ^os.File) {
		os.close(file)
		defer delete(op.read.buf, c.allocator)

		if op.read.err != nil {
			load_hosts_done(c, .Failed_Read, "read hosts file errno: %v", op.read.err)
			return
		}

		stream: strings.Reader
		strings.reader_init(&stream, string(op.read.buf))

		ok: bool
		c.hosts, ok = net.parse_hosts(strings.reader_to_stream(&stream), c.allocator)
		if !ok {
			load_hosts_done(c, .Failed_Read, "parse hosts failed")
			return
		}

		log.debugf("hosts:\n%s\nentries:\n%v", string(op.read.buf), c.hosts)

		load_hosts_done(c, .None)
	}

	file := os.new_file(uintptr(fd), hosts_file)

	stat, stat_err := os.fstat(file, c.allocator)
	if stat_err != nil {
		os.close(file)
		load_hosts_done(c, .Failed_Read, "could not stat hosts file at %q: %v", hosts_file, stat_err)
		return
	}
	defer os.file_info_delete(stat, c.allocator)

	buf, mem_err := make([]byte, stat.size, c.allocator)
	if mem_err != nil {
		os.close(file)
		load_hosts_done(c, .Failed_Open, "could not allocate buffer to read hosts file of size %m: %v", stat.size, mem_err)
		return
	}

	nbio.read_poly2(fd, 0, buf, c, file, on_hosts_content, all=true)
}

// TODO: this is wrong.
// @(private)
// change_dns_packet_family :: proc(buf: []byte, type: net.DNS_Record_Type) {
// 	parts := mem.slice_data_cast([]u16be, buf)
// 	parts[len(parts)-2] = u16be(type)
// }

@(private)
parse_record :: proc(packet: []byte, cur_off: ^int) -> (family: Address_Family, rec: Record, ok: bool) {
	record_buf := packet[cur_off^:]

	hn_sz := net.skip_hostname(packet, cur_off^) or_return

	ahdr_sz := size_of(net.DNS_Record_Header)
	if len(record_buf) - hn_sz < ahdr_sz {
		return
	}

	record_hdr_bytes := record_buf[hn_sz:hn_sz+ahdr_sz]
	record_hdr := cast(^net.DNS_Record_Header)raw_data(record_hdr_bytes)

	data_sz := record_hdr.length
	data_off := cur_off^ + int(hn_sz) + int(ahdr_sz)
	data := packet[data_off:data_off+int(data_sz)]
	cur_off^ += int(hn_sz) + int(ahdr_sz) + int(data_sz)

	#partial switch net.DNS_Record_Type(record_hdr.type) {
	case .IP4:
		if len(data) != 4 {
			return
		}

		addr := (^net.IP4_Address)(raw_data(data))^
		return .IP4, {
			address  = addr,
			ttl_secs = u32(record_hdr.ttl),
		}, true

	case .IP6:
		if len(data) != 16 {
			return
		}

		addr := (^net.IP6_Address)(raw_data(data))^
		return .IP6, {
			address  = addr,
			ttl_secs = u32(record_hdr.ttl),
		}, true

	case:
		return nil, {}, true
	}
}
