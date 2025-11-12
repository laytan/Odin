#+build !windows
package dns

import    "core:log"
import    "core:nbio"
import    "core:net"
import os "core:os/os2"

@(private)
_load_name_servers :: proc(c: ^Client) {
	resolv_conf := net.dns_configuration.resolv_conf
	if resolv_conf == "" {
	// TODO: this is not an error on Windows.
		load_name_servers_done(c, .No_Path, "the `net.DEFAULT_DNS_CONFIGURATION` does not contain a filepath to find the resolv conf file")
		return
	}

	log.debugf("reading resolv conf at %q", resolv_conf)

	fd, err := nbio.open(resolv_conf)
	if err != nil {
		load_name_servers_done(c, .Failed_Open, "the resolv conf at %q could not be opened due to errno: %v", resolv_conf, err)
		return
	}

	on_resolv_conf_content :: proc(op: ^nbio.Operation, c: ^Client, f: ^os.File) {
		os.close(f)
		defer delete(op.read.buf, c.allocator)

		if op.read.err != nil {
			load_name_servers_done(c, .Failed_Read, "read resolv conf error: %v", op.read.err)
			return
		}

		c.name_servers = net.parse_resolv_conf(string(op.read.buf), c.allocator)
		log.debugf("resolv_conf:\n%s\nname_servers:\n%v", string(op.read.buf), c.name_servers)

		load_name_servers_done(c, .None)
	}

	file := os.new_file(uintptr(fd), resolv_conf)

	stat, stat_err := os.fstat(file, c.allocator)
	if stat_err != nil {
		os.close(file)
		load_name_servers_done(c, .Failed_Read, "could not stat resolv conf at %q: %v", resolv_conf, stat_err)
		return
	}
	defer os.file_info_delete(stat, c.allocator)

	buf, mem_err := make([]byte, stat.size, c.allocator)
	if mem_err != nil {
		os.close(file)
		load_name_servers_done(c, .Failed_Read, "could not allocate buffer to read resolv_conf of size %m: %v", stat.size, mem_err)
		return
	}

	nbio.read_poly2(fd, buf, 0, c, file, on_resolv_conf_content, all=true)
}