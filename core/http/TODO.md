- Odin
	- core
		- net
			- http          | HTTP client and server
			- nbdns         | DNS client built on nbio
		- nbio                  | "Low" level asynchronous IO event loop
		- sys
			- linux
				- uring | IO Uring wrapper
			- kqueue        | Kqueue bindings
	 - vendor
	 	- openssl               | Minimal OpenSSL bindings enabling (plug-in) HTTPS in the HTTP client

# TODO

- [ ] Move packages into final spot (see tree above)
- [x] Make sure everything runs under `-sanitize:address`
- [ ] Remove README.md and rewrite relevant info and smaller example into `doc.odin`
- [x] Build/update openssl using CI (on a cron?)
- [x] move tests to listening on port 0 (which gets a port assigned by kernel) and query the actual port
- [ ] Get on framework benchmarks (can leave out DB tests (if I can't figure out why what I was doing is slow) I think)
	- [ ] benchmark the difference between the various nbio things with a callback vs taking over the event loop until an operation completes (http.body vs http.body_cb), if looping is fine, do that everywhere by default
- [x] Support the BSDs
	- [x] verify kqueue against bsd headers
- [x] Investigate timeouts on Windows? Just need to do the same as on posix
- [x] Check all recv calls and make sure they check `received == 0` which means the connection was orderly closed

## HTTP Server

- [ ] Consider switching the temp allocator back again to the custom `allocator.odin`, or remove it
	- [ ] could also use a pool of virtual arena's instead
- [ ] Set (more) timeouts
- [x] `http.io()` that returns `&http.td.io` or errors if it isn't one of the handler threads
- [x] `panic` when user does `free_all` on the given temp ally
- [x] in `http.respond`, set the `context.temp_allocator` back to the current connection's, so a user changing it doesn't fuck it up
- [x] Overload the router procs so you can do `route_get("/foo", foo)` instead of `route_get("/foo", http.handler(foo))`
- [ ] An API to write directly to the underlying socket, (to not have the overhead of buffering the body in memory)
	- [ ] Use it in respond_file things and maybe other places
- [ ] An API to read in a streamed fashion, maybe expose the scanner API used internally
- [x] Regex router
- [ ] Remove rate limit middleware; it's kinda bad/basic and easy to add userland
- [ ] Use SetConsoleCtrlHandler instead of catching signals on Windows - also add option to opt-out of handling this
- [ ] Ability to run multiple servers

## HTTP Client

- [ ] Proper error propagation
	- [ ] Dispose of a connection where an error happened (network error or 500 error (double check in RFC))
	- [ ] If there are queued requests, spawn a new connection for them
	- [x] If a connection is closed by the server, how does it get handled, retry configuration?
		- [ ] Make sure this doesn't infinitely loops, ie try this once and then error the request
- [ ] Expand configuration
    - [ ] Max response size
	- [ ] Timeouts
	- [ ] Max concurrency
- [x] Create a thin VTable interface for the OpenSSL functionality (so we can put openSSL in vendor and the rest in core)
- [x] Synchronous API (just take over the `nbio` event loop until the request is done)
- [ ] Poly API?
- [ ] Testing
	- [ ] Big requests > 16kb (a TLS packet)
- [x] Consider move into main package, but may be confusing?
- [x] Each host has multiple connections, when a request is made, get an available connection or make a new connection.
- [ ] Follow redirects
- [ ] Nice APIS wrapping over all the configuration for common actions

## DNS Client

- [ ] Windows
- [x] Should this really be it's own package?

## nbio

- [ ] Implement `with_timeout` everywhere
	- [x] Darwin
	- [x] Linux
	- [ ] Windows
- [ ] Make sure all procs are implemented everywhere (UDP & TCP, all platforms)
	- [x] Darwin
	- [x] Linux
	- [ ] Windows
- [x] Move the sub /poly package into the main one
- [x] Remove toggling the poly API
- [x] JS implementation
- [x] nbio.run that loops a tick, and returns when the event loop has nothing going on
- [x] remove `read` and `write` and force the offset, document why (Windows)
- [ ] do `time.now` at most once a tick (cache it), can probably add a `nbio.now(nbio.IO) -> time.Time` too
	- [x] Darwin
	- [x] Linux
	- [ ] Windows
- [x] check if some of the calls need to take a flags bitset. No
- [ ] don't use os.Errno or os package at all
	- [x] Darwin
	- [x] Linux
	- [ ] Windows
- [x] consider making the `IO` a thread local global
- [ ] calm down the cpu use
	- [x] Linux
	- [x] Darwin
	- [?] Windows
- [x] unaligned copy in core:thread poly procs

## WASM

- [x] HTTP Client backed by JS/WASM (This may have to be an additional, even higher level API, or, have the HTTP API be full of opaque structs and have getters)

# Nice to have

- [ ] Investigate sendfile and splice for Linux (if it can be used and where)

## Server

- [ ] Add an API to set a custom temp allocator

## Client

- [ ] Ingest cookies / Cookie JAR

## nbio

- [ ] A way to tick without blocking
