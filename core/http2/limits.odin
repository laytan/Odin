#+vet explicit-allocators
package http

import "core:mem"
import "core:time"

Limits :: struct {
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

// Default limits for receiving headers, this is intentionally permissive.
//
// Allow at least 20 seconds to receive the headers. If the client sends data, increase the timeout
// by 1 second for every 500 bytes received. But do not allow more than 40 seconds in total.
// Only accept up to 64 KiB of data containing the request line and headers.
@(rodata)
DEFAULT_HEADERS_LIMITS := Limits{
	max_size = 64 * mem.Kilobyte,
	min      = 20 * time.Second,
	max      = 40 * time.Second,
	min_rate = 500,
	rate_add = time.Second,
}

// Default limits for receiving bodies, this is intentionally permissive.
//
// Allow at least 20 seconds to receive the body. If the client sends data, increase the timeout
// by 1 second for every 500 bytes received. Up to 10 MiB total, with no absolute duration limit.
@(rodata)
DEFAULT_BODY_LIMITS := Limits{
	max_size = 10 * mem.Megabyte,
	min      = 20 * time.Second,
	max      = 0,
	min_rate = 500,
	rate_add = time.Second,
}

// Default limits for sending responses, this is intentionally permissive.
//
// Allow at least 20 seconds to read the body. If the client receives data, increase the timeout
// by 1 second for every 500 bytes sent. With no total limit (client may receive 500b/s indefinitely).
@(rodata)
DEFAULT_SEND_LIMITS := Limits{
	max_size = 0, // No max response size.
	min      = 20 * time.Second,
	max      = 0,
	min_rate = 500,
	rate_add = time.Second,
}

// Explicit unlimited opt-out for Server_Options fields (since zero Limits selects defaults).
@(rodata)
NO_LIMITS := Limits{
	max_size = -1,
	min      = -1,
	max      = -1,
	min_rate = -1,
	rate_add = -1,
}

Budget :: struct {
	limits: ^Limits,

	// Total transferred.
	transferred: int,
	// Total time spent doing IO.
	total: time.Duration,

	// The maximum amount of bytes to accept.
	// > 0: use as the maximum amount of bytes to allow transferring in the next IO operation.
	// = 0: do not do new IO, limit was exceeded.
	// < 0: no limit is configured.
	max: int,
	// > 0: use as timeout for next IO operation.
	// = 0: do not do new IO, timeout was exceeded.
	// < 0: no timeout is configured.
	timeout: time.Duration,
}

budget_reset :: proc(b: ^Budget, l: ^Limits) {
	b^ = {}
	budget_init(b, l)
}

budget_init :: proc(b: ^Budget, l: ^Limits) {
	assert(b.transferred == 0)
	assert(b.total == 0)
	budget_set_limits(b, l)
}

// Recomputes remaining max and timeout from l while accounting for bytes and duration already transferred.
budget_set_limits :: proc(b: ^Budget, l: ^Limits) {
	b.limits = l
	limits := l != nil ? l^ : {}
	b.max = limits.max_size > 0 ? max(0, limits.max_size - b.transferred) : -1

	if limits.min <= 0 && limits.max <= 0 {
		b.timeout = -1
		return
	}

	timeout: time.Duration
	if limits.min > 0 {
		timeout = limits.min - b.total
		if limits.min_rate > 0 && limits.rate_add > 0 && b.transferred > 0 {
			timeout += time.Duration((f64(b.transferred) / f64(limits.min_rate)) * f64(limits.rate_add))
		}
	} else {
		timeout = limits.max - b.total
	}

	if limits.max > 0 {
		allowed := max(0, limits.max - b.total)
		timeout = min(timeout, allowed)
	}

	b.timeout = max(0, timeout)
}

budget_next_timeout :: proc(b: Budget) -> time.Duration {
	return b.timeout
}

budget_max_transfer :: proc(b: Budget, available: int) -> int {
	if b.max < 0 {
		return available
	}

	return min(available, b.max)
}

budget_is_exhausted :: proc(b: Budget) -> bool {
	return b.max == 0 || b.timeout == 0
}

budget_update :: proc(b: ^Budget, transferred: int, dur: time.Duration) {
	assert(transferred > 0)
	assert(dur >= 0)

	l := b.limits != nil ? b.limits^ : {}
	b.transferred += transferred
	b.total += dur

	if b.max > 0 {
		b.max -= transferred
		b.max  = max(0, b.max)
	}

	if l.min_rate > 0 && dur > 0 {
		rate := f64(transferred) / time.duration_seconds(dur)
		if rate < f64(l.min_rate) {
			b.timeout = 0
			return
		}
	}

	if l.min > 0 {
		b.timeout -= dur

		if l.min_rate > 0 && l.rate_add > 0 {
			b.timeout += time.Duration((f64(transferred) / f64(l.min_rate)) * f64(l.rate_add))
		}

		if b.timeout <= 0 {
			b.timeout = 0
			return
		}
	}

	if l.max > 0 {
		allowed  := max(0, l.max - b.total)
		b.timeout = min(b.timeout, allowed)
	}
}
