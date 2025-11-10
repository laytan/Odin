package dns

import     "core:net"
import win "core:sys/windows"

@(private)
_load_name_servers :: proc(c: ^Client) {
	buf_len: win.ULONG
	if err := win.GetNetworkParams(nil, &buf_len); err != .BUFFER_OVERFLOW {
		load_name_servers_done(c, .Unsupported, "GetNetworkParams failed: %v", err)
		return
	}

	buf, buf_alloc_err := make([]byte, buf_len, c.allocator)
	if buf_alloc_err != nil {
		load_name_servers_done(c, .Failed_Read, "Allocation failed: %v", buf_alloc_err)
		return
	}
	defer delete(buf, c.allocator)

	info := (^win.FIXED_INFO)(raw_data(buf))
	if err := win.GetNetworkParams(info, &buf_len); err != nil {
		load_name_servers_done(c, .Unsupported, "GetNetworkParams failed: %v", err)
		return
	}

	name_servers_count := 0
	for server := &info.DnsServerList; server != nil; server = server.Next { name_servers_count += 1 }

	name_servers, name_servers_alloc_err := make([]net.Endpoint, name_servers_count, c.allocator)
	if name_servers_alloc_err != nil {
		load_name_servers_done(c, .Failed_Read, "Allocation failed: %v", name_servers_alloc_err)
		return
	}

	for server, i := &info.DnsServerList, 0; server != nil; server, i = server.Next, i + 1 {
		addr_str := cstring(raw_data(&server.IpAddress.String))
		addr := net.parse_address(string(addr_str))
		name_servers[i] = net.Endpoint{addr, 53}
	}

	c.name_servers = name_servers
	load_name_servers_done(c, .None)
}
