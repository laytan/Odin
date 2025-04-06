#+build !windows
#+build !linux
#+build !darwin
#+build !freebsd
package net

@(private)
_get_dns_records_os :: proc(hostname: string, type: DNS_Record_Type, allocator := context.allocator) -> (records: []DNS_Record, err: DNS_Error) {
	return
}
