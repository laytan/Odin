- Odin
	- core
		- net
			- http         | HTTP client and server
			- dns          | DNS client built on asyncio
		- io
			- asyncio      | "Low" level asynchronous IO event loop
		- sys
			- linux
				- io_uring | IO Uring API
			- kqueue       | Kqueue bindings
	 - vendor
	 	- openssl          | Minimal OpenSSL bindings enabling (plug-in) HTTPS in the HTTP client

# TODO

- [ ] Make sure everything runs under `-sanitize:address`
- [ ] Remove README.md and rewrite relevant info and smaller example into `doc.odin`
- [x] Build/update openssl using CI (on a cron?)

## HTTP Server

- [ ] Consider switching the temp allocator back again to the custom `allocator.odin`, or remove it
- [ ] Set (more) timeouts
- [x] `http.io()` that returns `&http.td.io` or errors if it isn't one of the handler threads
- [ ] `panic` when user does `free_all` on the given temp ally
- [ ] in `http.respond`, set the `context.temp_allocator` back to the current connection's, so a user changing it doesn't fuck it up

## HTTP Client

- [ ] Proper error propagation
	- [ ] Dispose of a connection where an error happened (network error or 500 error (double check in RFC))
	- [ ] If there are queued requests, spawn a new connection for them
	- [x] If a connection is closed by the server, how does it get handled, retry configuration?
		- [ ] Make sure this doesn't infinitely loops, ie try this once and then error the request
- [ ] Expand configuration
    - [ ] Max response size
	- [ ] Timeouts
- [x] Create a thin VTable interface for the OpenSSL functionality (so we can put openSSL in vendor and the rest in core)
- [ ] Synchronous API (just take over the `nbio` event loop until the request is done)
- [ ] API that takes over event loop until all pending requests are completed
- [ ] Poly API
- [ ] Testing
	- [ ] Big requests > 16kb (a TLS packet)
- [x] Consider move into main package, but may be confusing?
- [ ] Each host has multiple connections, when a request is made, get an available connection or make a new connection.

## DNS Client

- [ ] Windows
- [ ] Should this really be it's own package?

## nbio

- [ ] Implement `with_timeout` everywhere
- [ ] Make sure all procs are implemented everywhere (UDP & TCP, all platforms)
- [x] Move the sub /poly package into the main one
- [x] Remove toggling the poly API
- [x] JS implementation
- [x] nbio.run that loops a tick, and returns when the event loop has nothing going on
- [x] remove `read` and `write` and force the offset, document why (Windows)
- [ ] do `time.now` at most once a tick (cache it), can probably add a `nbio.now(nbio.IO) -> time.Time` too
- [ ] check if some of the calls need to take a flags bitset.
- [ ] don't use os.Errno or os package at all
- [ ] consider making the `IO` a thread local global

# Non critical wants

- [ ] Get on framework benchmarks (can leave out DB tests (if I can't figure out why what I was doing is slow) I think)
- [ ] Support the BSDs
	- [ ] verify kqueue against bsd headers

## HTTP Server

- [ ] Add an API to set a custom temp allocator
- [ ] Overload the router procs so you can do `route_get("/foo", foo)` instead of `route_get("/foo", http.handler(foo))`
- [ ] A way to say: "get the body before calling this handler"
- [ ] An API to write directly to the underlying socket, (to not have the overhead of buffering the body in memory)

## HTTP Client

- [ ] Follow redirects
- [ ] Ingest cookies / Cookie JAR
- [ ] Nice APIS wrapping over all the configuration for common actions

## WASM

- [x] HTTP Client backed by JS/WASM (This may have to be an additional, even higher level API, or, have the HTTP API be full of opaque structs and have getters)
