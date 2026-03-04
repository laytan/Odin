#+build ignore
package http

import "core:mem/virtual"
import "core:mem"
import "core:nbio"
import "core:container/xar"
import "base:sanitizer"

// lifetimes
// 1 connection
// 2 transaction

Connections :: struct {
	free:    ^Connection,
	entries: xar.Array(Connection, 8),
}

connections_init :: proc(cs: ^Connections, allocator: mem.Allocator) {
	cs.entries.allocator = allocator
}

connections_destroy :: proc(cs: ^Connections) {
	xar.destroy(&cs.entries)
}

Connections_Iterator :: distinct xar.Iterator

connections_iterator :: proc(cs: ^Connections) -> Connections_Iterator(Connection, 8) {
	return auto_cast xar.iterator(&cs.entries)
}

connections_iterate :: proc(iter: ^Connections_Iterator(Connection, 8)) -> (c: ^Connection, ok: bool) {
	for {
		c = xar.iterate_by_ptr(cast(^xar.Iterator(Connection, 8)) iter) or_return
		sanitizer.address_unpoison(c)
		if c.state == .Free {
			sanitizer.address_poison(c)
			continue
		}

		return c, true
	}
}

connections_get :: proc(cs: ^Connections) -> ^Connection {
	if cs.free != nil {
		c := cs.free
		sanitizer.address_unpoison(c)
		cs.free = c.next
		mem.zero_item(c)
		c.state = .Pending
	}

	c, _ := xar.append_and_get_ptr(&cs.entries, Connection{})
	return c
}

connections_put :: proc(cs: ^Connections, c: ^Connection) {
	c.next  = cs.free
	c.state = .Free
	cs.free = c
	sanitizer.address_poison(c)
}

Connection :: struct {
	next:    ^Connection,
	transactions: [2]Transaction,
	transaction:  int,
	socket:  nbio.TCP_Socket,
	recv:    ^nbio.Operation,
	state:   Connection_State,
	scanner: Scanner, // TODO: simplify / inline scanner
}

Transaction :: struct {
	conn: ^Connection,
	arena: virtual.Arena, // TODO: different allocator
	ctx:   Context,
	req:   Request,
	res:   Response,
}

transaction_allocator :: proc(t: ^Transaction) -> mem.Allocator {
	return virtual.arena_allocator(&t.arena)	
}

transaction :: proc(c: ^Connection) -> ^Transaction #no_bounds_check {
	return &c.transactions[c.transaction]
}

// read request 1
// call handler for 1
// after body retrieval (or if the request has no body) read request 2
// wait for handler 1 to finish sending it's response
// call handler for 2
// repeat


