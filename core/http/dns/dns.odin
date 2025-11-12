// A fully non-blocking DNS client with TTL caching.
package dns

import "base:runtime"

import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:time"
import os "core:os/os2"

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
	callbacks: [dynamic]Callback,
	evictor:   ^nbio.Operation,
}

@(private)
Callback :: struct {
	cb:  On_Resolve,
	ud:  rawptr,
	ctx: runtime.Context,
}

init :: proc(c: ^Client, user_data: rawptr, on_init: On_Init, allocator := context.allocator) {
	c.allocator = allocator
	c.cache.allocator = allocator

	c.init_cb = on_init
	c.init_ud = user_data

	c.name_servers_err = _INIT_ERROR_LOADING
	c.hosts_err        = _INIT_ERROR_LOADING

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
	context.user_ptr = &name_servers_err
	init(c, &hosts_err, proc(c: ^Client, user: rawptr, name_servers_err: Init_Error, hosts_err: Init_Error) {
		(^Init_Error)(context.user_ptr)^ = name_servers_err
		(^Init_Error)(user)^ = hosts_err
	})

	for {
		errno := nbio.tick()
		if errno != nil {
			ok = false
			return
		}

		if name_servers_err != _INIT_ERROR_LOADING && hosts_err != _INIT_ERROR_LOADING {
			ok = true
			return
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
	for k in c.cache {
		if to_remove <= 0 {
			break
		}

		cache_evict(c, k)

		to_remove -= 1
	}
}

On_Resolve :: #type proc(user: rawptr, record: Record, err: net.Network_Error)

@(private)
Request :: struct {
	client:      ^Client,
	hostname:    string,
	name_server: int,
	packet:      [net.DNS_PACKET_MIN_LEN]byte,
	packet_len:  int,
	response:    [4096]byte,
	family:      Address_Family,
	socket:      net.UDP_Socket,
	err:         net.Network_Error,
}

Address_Family :: enum {
	None,
	IP4,
	IP6,
}

// Resolve the given hostname to an IP4 or IP6 address.
//
// The given `hostname` string is copied internally and can thus be temporary.
//
// On completion, the request/response is cached for further use, and a timeout is added to the
// event loop to evict the record after the returned time to live.
//
// General Process:
// In the cache?
//   Yes - Still resolving?
//     Yes - Add callback to list of callbacks that are called after resolving
//     No  - Call the callback with DNS record from the cache
//   No - Check for matches in the user's hosts file (`/etc/hosts` for example), is it there?
//     Yes - Call callback with match
//     No  - Start resolving, create in progress cache entry send IP4 request to the first name server
//           retrieved from the user's resolv file (`/etc/resolv.conf` for example)
//           Each name server is given a timeout of `DNS_SERVER_TIMEOUT` to respond,
//           if it doesn't respond or if it fails (error or no result) the next name server is tried.
//           If all name servers haven't returned any result for IP4, the same loop over all name servers
//           is started for IP6. Did any name server respond with an address?
//             Yes - Complete the cache entry and call all queued callbacks,
//                   and add a timeout for the returned time to live (with a `MAX_TTL_SECONDS` maximum)
//                   seconds to the event loop which on completion evicts the record from the cache.
//             No  - Complete the cache entry with an error and call all queued callbacks,
//                   and add a timeout for 1 minute for the record to be evicted from the cache.
resolve :: proc(c: ^Client, hostname: string, user: rawptr, cb: On_Resolve) {
	log.debugf("resolving DNS for %q", hostname)

	if cached, ok := &c.cache[hostname]; ok {
		if cached.resolving {
			log.debugf("already resolving DNS of %q, adding to callback queue", hostname)
			append(&cached.callbacks, Callback{cb, user, context})
		} else {
			log.debugf("got DNS of %q from cache", hostname)
			cb(user, cached.record, cached.err)
		}
		return
	}

	log.debugf("%q not in cache", hostname)

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

	log.debugf("%q not in hosts file", hostname)

	if len(c.name_servers) == 0 {
		log.warn("no name servers to query for DNS records")
		cb(user, {}, .Unable_To_Resolve)
		return
	}

	log.debug("querying name servers for IP4 records")

	host := strings.clone(hostname, c.allocator)

	entry := map_insert(&c.cache, host, Cache_Entry{ resolving = true })
	entry.callbacks = make([dynamic]Callback, 1, c.allocator)
	entry.callbacks[0] = {cb, user, context}

	req := new(Request, c.allocator)
	req.hostname = host
	req.family   = .IP4

	packet, err := net.make_dns_packet(req.packet[:], 0, hostname, .IP4)
	if err != nil {
		free(req, req.client.allocator)
		cb(user, {}, err)
		return
	}
	req.packet_len = len(packet)

	req.client = c
	req.name_server = -1

	next(req, nil)

	next :: proc(req: ^Request, err: net.Network_Error) {
		if err != nil {
			log.warnf("name server %v query errored: %v", req.client.name_servers[req.name_server], err)
			req.err = err
		}

		if req.socket != {} {
			log.debug("closing socket of previous name server")
			nbio.close(req.socket)
		}

		req.name_server += 1
		if req.name_server >= len(req.client.name_servers) {
			#partial switch req.family {
			case .IP4:
				log.debug("no DNS results gotten from IP4, querying name servers for IP6")
				req.family = .IP6
				req.name_server = -1
				change_dns_packet_family(req.packet[:req.packet_len], .DNS_TYPE_NS)
				next(req, nil)
			case .IP6:
				entry := &req.client.cache[req.hostname]
				entry.err = .Unable_To_Resolve if req.err == nil else req.err
				entry.resolving = false
				log.warn("no DNS results gotten from IP6 either, calling callbacks with error:", entry.err)

				// Evict the cached error after a minute.
				nbio.timeout_poly2(time.Minute, req.client, req.hostname, evict_record)

				free(req, req.client.allocator)

				for cb in entry.callbacks {
					context = cb.ctx
					cb.cb(cb.ud, {}, entry.err)
				}
				delete(entry.callbacks)
			case:
				unreachable()
			}
			return
		}

		ns := req.client.name_servers[req.name_server]
		family := net.family_from_address(ns.address)

		log.debugf("quering name server %v over %v", ns, family)

		sock, oerr := nbio.create_socket(family, .UDP)
		if oerr != nil {
			log.warnf("could not open UDP socket to name server: %v", oerr)
			next(req, oerr)
			return
		}
		req.socket = sock.(net.UDP_Socket)

		nbio.send_poly(req.socket, req.packet[:req.packet_len], req, on_sent, ns)
	}

	on_record :: proc(req: ^Request, rec: Record) {
		log.debug("got DNS record", rec)
		nbio.close(req.socket)

		entry := &req.client.cache[req.hostname]
		entry.resolving = false
		entry.record = rec

		expires := time.Second*time.Duration(clamp(rec.ttl_secs, 0, MAX_TTL_SECONDS))
		entry.evictor = nbio.timeout_poly2(expires, req.client, req.hostname, evict_record)

		for cb in entry.callbacks {
			context = cb.ctx
			cb.cb(cb.ud, rec, nil)
		}

		free(req, req.client.allocator)
		delete(entry.callbacks)
	}

	evict_record :: proc(_: ^nbio.Operation, c: ^Client, hostname: string) {
		if entry, ok := c.cache[hostname]; ok {
			log.debugf("DNS TTL of %vs from %q has expired", entry.record.ttl_secs, hostname)
			delete_key(&c.cache, hostname)
			delete(hostname, c.allocator)
		}
	}

	on_sent :: proc(op: ^nbio.Operation, req: ^Request) {
		log.debugf("sent a %m packet with %v err, receiving response", op.send.sent, op.send.err)
		if op.send.err != nil {
			next(req, op.send.err.(net.UDP_Send_Error))
			return
		}

		nbio.recv_poly(req.socket, req.response[:], req, on_recv, timeout=DNS_SERVER_TIMEOUT)
	}

	on_recv :: proc(op: ^nbio.Operation, req: ^Request) {
		log.debugf("received a %m packet with %v err, parsing", op.recv.received, op.recv.err)
		if op.recv.err != nil {
			next(req, op.recv.err.(net.UDP_Recv_Error))
			return
		}

		if op.recv.received == 0 {
			next(req, nil)
			return
		}

		// TODO: could we have gotten a partial response back and need to read more?
		response := req.response[:op.recv.received]

		HEADER_SIZE_BYTES :: 12
		if len(response) < HEADER_SIZE_BYTES {
			next(req, nil)
			return
		}

		dns_hdr_chunks := mem.slice_data_cast([]u16be, response[:HEADER_SIZE_BYTES])
		hdr := net.unpack_dns_header(dns_hdr_chunks[0], dns_hdr_chunks[1])
		if !hdr.is_response {
			next(req, nil)
			return
		}

		question_count := int(dns_hdr_chunks[2])
		if question_count != 1 {
			next(req, nil)
			return
		}

		answer_count     := int(dns_hdr_chunks[3])
		authority_count  := int(dns_hdr_chunks[4])
		additional_count := int(dns_hdr_chunks[5])

		cur_idx := HEADER_SIZE_BYTES

		dq_sz :: 4
		hn_sz, hs_ok := net.skip_hostname(response, cur_idx)
		if !hs_ok {
			next(req, nil)
			return
		}
		cur_idx += hn_sz + dq_sz

		for _ in 0..<answer_count+authority_count+additional_count {
			if cur_idx >= len(response) {
				continue
			}

			family, rec, ok := parse_record(response, &cur_idx)
			if !ok {
				next(req, nil)
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

	fd, err := nbio.open(hosts_file)
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

		c.hosts = net.parse_hosts(string(op.read.buf), c.allocator)
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

	nbio.read_poly2(fd, buf, 0, c, file, on_hosts_content, all=true)
}

@(private)
change_dns_packet_family :: proc(buf: []byte, type: net.DNS_Record_Type) {
	parts := mem.slice_data_cast([]u16be, buf)
	parts[len(parts)-2] = u16be(type)
}

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
