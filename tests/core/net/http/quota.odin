package test_core_net_http

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:testing"
import "core:time"
import http "core:http2"

@(test)
progression_update :: proc(t: ^testing.T) {
	Test_Case :: struct {
		description:       string,
		input_progression: http.Progression,
		input_quota:       http.Quota,
		transferred:       int,
		dur:               time.Duration,
		output:            http.Progression,
	}

	cases := [?]Test_Case{
		{
            description = "1. Max size decreases correctly (not exhausted)",
            input_progression = { transferred = 0, total = 0, max = 1000, timeout = -1 },
            input_quota = { max_size = 1000, min = 0, max = 0, min_rate = 0, rate_add = 0 },
            transferred = 400,
            dur = time.Second,
            output = { transferred = 400, total = time.Second, max = 600, timeout = -1 },
        },
        {
            description = "2. Max size hits zero when limit is exceeded",
            input_progression = { transferred = 500, total = time.Second, max = 200, timeout = -1 },
            input_quota = { max_size = 700, min = 0, max = 0, min_rate = 0, rate_add = 0 },
            transferred = 300,
            dur = time.Second,
            output = { transferred = 800, total = 2 * time.Second, max = 0, timeout = -1 },
        },
        {
            description = "3. Fails minimum rate requirement (timeout goes to 0)",
            input_progression = { transferred = 0, total = 0, max = -1, timeout = 20 * time.Second },
            input_quota = { max_size = 0, min = 20 * time.Second, max = 0, min_rate = 500, rate_add = 0 },
            transferred = 400, // 400 bytes in 1s < 500 bytes/s
            dur = time.Second,
            output = { transferred = 400, total = time.Second, max = -1, timeout = 0 },
        },
        {
            description = "4. Meets min rate, timeout is consumed but extended by rate_add",
            input_progression = { transferred = 0, total = 0, max = -1, timeout = 20 * time.Second },
            input_quota = { max_size = 0, min = 20 * time.Second, max = 0, min_rate = 500, rate_add = time.Second },
            transferred = 1000, // Grants +2 seconds, consumed 1 second. Net +1.
            dur = time.Second,
            output = { transferred = 1000, total = time.Second, max = -1, timeout = 21 * time.Second },
        },
        {
            description = "5. Timeout completely consumed (hits zero and returns)",
            input_progression = { transferred = 0, total = 0, max = -1, timeout = 5 * time.Second },
            input_quota = { max_size = 0, min = 5 * time.Second, max = 0, min_rate = 0, rate_add = 0 },
            transferred = 1000,
            dur = 6 * time.Second, // Used more time than timeout allowed
            output = { transferred = 1000, total = 6 * time.Second, max = -1, timeout = 0 },
        },
        {
            description = "6. Timeout bonus granted but clamped by absolute max total",
            input_progression = { transferred = 0, total = 30 * time.Second, max = -1, timeout = 20 * time.Second },
            input_quota = { max_size = 0, min = 20 * time.Second, max = 40 * time.Second, min_rate = 500, rate_add = time.Second },
            transferred = 5000, // Grants +10 seconds (5000/500 * 1)
            dur = 5 * time.Second, 
            // Total becomes 35s. Absolute max is 40s. 
            // Allowed remaining is 5s. 
            // Timeout (20 - 5 + 10 = 25) gets clamped to 5s.
            output = { transferred = 5000, total = 35 * time.Second, max = -1, timeout = 5 * time.Second },
        },
        {
            description = "7. Immediate transfer (dur=0) skips rate check and grants fractional time",
            input_progression = { transferred = 0, total = 0, max = -1, timeout = 20 * time.Second },
            input_quota = { max_size = 0, min = 20 * time.Second, max = 0, min_rate = 500, rate_add = time.Second },
            transferred = 100,
            dur = 0,
            // rate_add is added cleanly: (100 / 500) * 1s = 200ms
            output = { transferred = 100, total = 0, max = -1, timeout = 20 * time.Second + 200 * time.Millisecond },
        },
        {
            description = "8. Absolute max perfectly exhausted (timeout goes to 0)",
            input_progression = { transferred = 0, total = 38 * time.Second, max = -1, timeout = 5 * time.Second },
            input_quota = { max_size = 0, min = 0, max = 40 * time.Second, min_rate = 0, rate_add = 0 },
            transferred = 1000,
            dur = 2 * time.Second,
            // Total hits 40s (max allowed). Remaining allowed is 0.
            output = { transferred = 1000, total = 40 * time.Second, max = -1, timeout = 0 },
        },
	}

	for &c in cases {
		http.progression_update(&c.input_progression, c.input_quota, c.transferred, c.dur)
		if !testing.expect_value(t, c.input_progression, c.output) {
			log.errorf("FAIL: %s", c.description)
		}
	}
}

@(test)
test_server_options_default_and_unlimited_quotas :: proc(t: ^testing.T) {
	default_server := http.make_server({})
	testing.expect_value(t, http.DEFAULT_HEADERS_QUOTA.max_size, 64 * mem.Kilobyte)
	testing.expect_value(t, http.DEFAULT_BODY_QUOTA.max_size, 10 * mem.Megabyte)
	testing.expect_value(t, default_server.opts.request_quota, http.DEFAULT_HEADERS_QUOTA)
	testing.expect_value(t, default_server.opts.body_quota, http.DEFAULT_BODY_QUOTA)
	testing.expect_value(t, default_server.opts.response_quota, http.DEFAULT_SEND_QUOTA)
	testing.expect_value(t, default_server.opts.max_headers, http.DEFAULT_MAX_HEADERS)

	custom_quota := http.Quota{max_size = 1234, min = 5 * time.Second}
	unlimited_server := http.make_server({
		request_quota  = custom_quota,
		body_quota     = http.UNLIMITED_QUOTA,
		response_quota = http.UNLIMITED_QUOTA,
	})
	testing.expect_value(t, unlimited_server.opts.request_quota, custom_quota)
	testing.expect_value(t, unlimited_server.opts.body_quota, http.UNLIMITED_QUOTA)
	testing.expect_value(t, unlimited_server.opts.response_quota, http.UNLIMITED_QUOTA)

	p: http.Progression
	http.progression_init(&p, http.UNLIMITED_QUOTA)
	testing.expect_value(t, p.max, -1)
	testing.expect_value(t, p.timeout, time.Duration(-1))
	testing.expect(t, !http.progression_is_exhausted(p))

	http.progression_update(&p, http.UNLIMITED_QUOTA, 1_000_000, 10 * time.Minute)
	testing.expect_value(t, p.max, -1)
	testing.expect_value(t, p.timeout, time.Duration(-1))
	testing.expect(t, !http.progression_is_exhausted(p))
}

@(test)
test_per_request_and_response_quota_overrides :: proc(t: ^testing.T) {
	// 1. Fresh state with pointer overload (zero-alloc, points directly to caller's Quota).
	req: http.Request
	q_fresh := http.Quota{
		max_size = 1000,
		min      = 10 * time.Second,
		max      = 30 * time.Second,
		min_rate = 500,
		rate_add = time.Second,
	}
	http.request_set_quota(&req, &q_fresh)
	testing.expect_value(t, req.quota, &q_fresh)
	testing.expect_value(t, req.quota^, q_fresh)
	testing.expect_value(t, req.progress.max, 1000)
	testing.expect_value(t, req.progress.timeout, 10 * time.Second)

	res: http.Response
	http.response_set_quota(&res, &q_fresh)
	testing.expect_value(t, res.quota, &q_fresh)
	testing.expect_value(t, res.quota^, q_fresh)
	testing.expect_value(t, res.progress.max, 1000)
	testing.expect_value(t, res.progress.timeout, 10 * time.Second)

	// 2. Partially transferred state accounts for transferred bytes & elapsed duration.
	req.progress.transferred = 1000
	req.progress.total = 3 * time.Second
	q_override := http.Quota{
		max_size = 5000,
		min      = 10 * time.Second,
		max      = 20 * time.Second,
		min_rate = 500,
		rate_add = time.Second,
	}
	http.request_set_quota(&req, &q_override)
	testing.expect_value(t, req.quota, &q_override)
	// max = 5000 - 1000 = 4000
	testing.expect_value(t, req.progress.max, 4000)
	// timeout = 10s - 3s + (1000 / 500) * 1s = 9s (< max - total = 17s)
	testing.expect_value(t, req.progress.timeout, 9 * time.Second)

	// Overriding to a smaller max_size than already transferred floors max at 0.
	q_small := http.Quota{max_size = 500, min = 5 * time.Second, max = 4 * time.Second}
	res.progress.transferred = 600
	res.progress.total = 5 * time.Second
	http.response_set_quota(&res, &q_small)
	testing.expect_value(t, res.quota, &q_small)
	testing.expect_value(t, res.progress.max, 0)
	testing.expect_value(t, res.progress.timeout, time.Duration(0))

	// Overriding to UNLIMITED_QUOTA via pointer clears both limits regardless of prior usage.
	q_unlimited := http.UNLIMITED_QUOTA
	http.request_set_quota(&req, &q_unlimited)
	testing.expect_value(t, req.progress.max, -1)
	testing.expect_value(t, req.progress.timeout, time.Duration(-1))

	// 3. Body size checks honor request_set_quota overrides in both directions.
	s := http.make_server({})
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	setup_body_conn :: proc(t: ^testing.T, c: ^http.Connection, quota: ^http.Quota, clen_str, payload: string) {
		c^ = http.Connection{
			transaction_arena = http.get_arena(nil),
			temp_arena        = http.get_arena(nil),
		}
		c.transaction_arena.c = c
		c.temp_arena.c = c

		tx_alloc := http.transaction_allocator(c)
		c.vars.allocator = tx_alloc
		c.req.headers.allocator = tx_alloc
		c.res.headers.allocator = tx_alloc
		c.res.buf.allocator = tx_alloc
		c.scanner.c = c
		c.scanner.allocator = &c.transaction_arena

		c.res.state = .Handling
		c.res.progress.max = 0
		c.res.sends = 1

		c.req.quota = quota
		http.progression_reset(&c.req.progress, quota^)

		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Content-Length", clen_str), nil)
		http._headers_set_readonly(&c.req.headers)

		if len(payload) > 0 {
			buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
			testing.expect_value(t, buf_err, nil)
			c.scanner.buf = buf
			c.scanner.write_head = copy(buf, payload)
		}
	}

	cleanup_body_conn :: proc(c: ^http.Connection) {
		http.temp_allocator_destroy(c)
		http.transaction_allocator_destroy(c)
	}

	Body_Check :: struct {
		t:    ^testing.T,
		done: bool,
		len:  int,
	}

	// Loosening: initial tight limit (8 bytes) lifted via request_set_quota allows 16-byte body.
	{
		c: http.Connection
		tight := http.Quota{max_size = 8}
		setup_body_conn(t, &c, &tight, "16", "0123456789abcdef")
		defer cleanup_body_conn(&c)

		req_unlimited := http.UNLIMITED_QUOTA
		http.request_set_quota(&c.req, &req_unlimited)
		testing.expect_value(t, c.req.quota, &req_unlimited)
		testing.expect_value(t, c.req.progress.max, -1)

		res_custom := http.Quota{max_size = 42, min = 3 * time.Second}
		http.response_set_quota(&c.res, &res_custom)
		testing.expect_value(t, c.res.quota, &res_custom)
		testing.expect_value(t, c.res.progress.max, 42)
		testing.expect_value(t, c.res.progress.timeout, 3 * time.Second)

		chk := http.context_add(&c.ctx, Body_Check{t = t})
		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {
			chk := http.context_get(http.context_of_request(req), Body_Check)
			chk.len += len(body)
			if !is_partial {
				chk.done = true
			}
		})
		testing.expect(t, chk.done)
		testing.expect_value(t, chk.len, 16)
	}

	// Tightening: DEFAULT_BODY_QUOTA reduced via request_set_quota rejects 16-byte body with 413.
	{
		c: http.Connection
		default_body := http.DEFAULT_BODY_QUOTA
		setup_body_conn(t, &c, &default_body, "16", "")
		defer cleanup_body_conn(&c)

		req_tight := http.Quota{max_size = 8}
		http.request_set_quota(&c.req, &req_tight)
		testing.expect_value(t, c.req.quota, &req_tight)
		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect(t, c.res.state == .Error)
	}
}
