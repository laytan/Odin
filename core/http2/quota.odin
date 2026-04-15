package http

import "core:mem"
import "core:time"

Quota :: struct {
	// The maximum amount of bytes to potentially transfer.
	max_size: int,
	// The minimum time after which a client may be disconnected.
	min:      time.Duration,
	// The absolute maximum time the client may take.
	max:      time.Duration,
	// The minimum flow rate (bytes per second) a client must hold.
	min_rate: int,
	// Every `min_rate` bytes transferred adds this amount of time to the allowed timeout (up to `max`).
	rate_add: time.Duration,
}

// Default quota for receiving headers, this is intentionally permissive.
//
// Allow at least 20 seconds to receive the headers. If the client sends data, increase the timeout
// by 1 second for every 500 bytes received. But do not allow more than 40 seconds in total.
// Only accept up to a MiB of data containing the request line and headers.
DEFAULT_HEADERS_QUOTA :: Quota{
	max_size = mem.Megabyte,
	min      = 20 * time.Second,
	max      = 40 * time.Second,
	min_rate = 500,
	rate_add = time.Second,
}

// Default quota for receiving bodies, this is intentionally permissive.
//
// Allow at least 20 seconds to receive the body. If the client sends data, increase the timeout
// by 1 second for every 500 bytes received. With no total limit (client may send 500b/s indefinitely).
DEFAULT_BODY_QUOTA :: Quota{
	max_size = 0, // No max body size.
	min      = 20 * time.Second,
	max      = 0,
	min_rate = 500,
	rate_add = time.Second,
}

// Default quota for sending responses, this is intentionally permissive.
//
// Allow at least 20 seconds to read the body. If the client receives data, increase the timeout
// by 1 second for every 500 bytes sent. With no total limit (client may receive 500b/s indefinitely).
DEFAULT_SEND_QUOTA :: Quota{
	max_size = 0, // No max response size.
	min      = 20 * time.Second,
	max      = 0,
	min_rate = 500,
	rate_add = time.Second,
}

Progression :: struct {
	// Total transferred.
	transferred: int,
	// Total time spent doing IO.
	total: time.Duration,

	// The maximum amount of bytes to accept.
	// > 0: use as the maximum amount of bytes to allow transferring in the next IO operation.
	// = 0: do not do new IO, limit was exceeded.
	// < 0: no limit is configured.
	// TODO: allow setting for a specific request.
	max: int,
	// > 0: use as timeout for next IO operation.
	// = 0: do not do new IO, timeout was exceeded.
	// < 0: no timeout is configured.
	timeout: time.Duration,
}

progression_reset :: proc(p: ^Progression, q: Quota) {
	p.transferred = 0
	p.total = 0
	progression_init(p, q)
}

progression_init :: proc(p: ^Progression, q: Quota) {
	assert(p.transferred == 0)
	assert(p.total == 0)
	p.max     = q.max_size > 0 ? q.max_size : -1
	p.timeout = q.min > 0 ? q.min : (q.max > 0 ? q.max : -1)
}

// TODO: unit test
progression_update :: proc(p: ^Progression, q: Quota, transferred: int, dur: time.Duration) {
	assert(transferred > 0)
	assert(dur >= 0)

	p.transferred += transferred
	p.total += dur

	if p.max > 0 {
		p.max -= transferred
		p.max  = max(0, p.max)
	}

	if q.min_rate > 0 && dur > 0 {
		rate := f64(transferred) / time.duration_seconds(dur)
		if rate < f64(q.min_rate) {
			p.timeout = 0
			return
		}
	}

	if q.min > 0 {
		p.timeout -= dur

		if q.min_rate > 0 && q.rate_add > 0 {
			p.timeout += time.Duration((f64(transferred) / f64(q.min_rate)) * f64(q.rate_add))
		}

		if p.timeout <= 0 {
			p.timeout = 0
			return
		}
	}

	if q.max > 0 {
		allowed  := max(0, q.max - p.total)
		p.timeout = min(p.timeout, allowed)
	}
}
