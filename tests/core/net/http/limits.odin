package test_core_net_http

import "core:log"
import "core:mem"
import "core:testing"
import "core:time"
import http "core:http2"

@(test)
budget_update :: proc(t: ^testing.T) {
	Test_Case :: struct {
		description:  string,
		input_budget: http.Budget,
		input_limits: http.Limits,
		transferred:  int,
		dur:          time.Duration,
		output:       http.Budget,
	}

	cases := [?]Test_Case{
		{
            description = "1. Max size decreases correctly (not exhausted)",
            input_budget = { transferred = 0, total = 0, max = 1000, timeout = -1 },
            input_limits = { max_size = 1000, min = 0, max = 0, min_rate = 0, rate_add = 0 },
            transferred = 400,
            dur = time.Second,
            output = { transferred = 400, total = time.Second, max = 600, timeout = -1 },
        },
        {
            description = "2. Max size hits zero when limit is exceeded",
            input_budget = { transferred = 500, total = time.Second, max = 200, timeout = -1 },
            input_limits = { max_size = 700, min = 0, max = 0, min_rate = 0, rate_add = 0 },
            transferred = 300,
            dur = time.Second,
            output = { transferred = 800, total = 2 * time.Second, max = 0, timeout = -1 },
        },
        {
            description = "3. Fails minimum rate requirement (timeout goes to 0)",
            input_budget = { transferred = 0, total = 0, max = -1, timeout = 20 * time.Second },
            input_limits = { max_size = 0, min = 20 * time.Second, max = 0, min_rate = 500, rate_add = 0 },
            transferred = 400, // 400 bytes in 1s < 500 bytes/s
            dur = time.Second,
            output = { transferred = 400, total = time.Second, max = -1, timeout = 0 },
        },
        {
            description = "4. Meets min rate, timeout is consumed but extended by rate_add",
            input_budget = { transferred = 0, total = 0, max = -1, timeout = 20 * time.Second },
            input_limits = { max_size = 0, min = 20 * time.Second, max = 0, min_rate = 500, rate_add = time.Second },
            transferred = 1000, // Grants +2 seconds, consumed 1 second. Net +1.
            dur = time.Second,
            output = { transferred = 1000, total = time.Second, max = -1, timeout = 21 * time.Second },
        },
        {
            description = "5. Timeout completely consumed (hits zero and returns)",
            input_budget = { transferred = 0, total = 0, max = -1, timeout = 5 * time.Second },
            input_limits = { max_size = 0, min = 5 * time.Second, max = 0, min_rate = 0, rate_add = 0 },
            transferred = 1000,
            dur = 6 * time.Second, // Used more time than timeout allowed
            output = { transferred = 1000, total = 6 * time.Second, max = -1, timeout = 0 },
        },
        {
            description = "6. Timeout bonus granted but clamped by absolute max total",
            input_budget = { transferred = 0, total = 30 * time.Second, max = -1, timeout = 20 * time.Second },
            input_limits = { max_size = 0, min = 20 * time.Second, max = 40 * time.Second, min_rate = 500, rate_add = time.Second },
            transferred = 5000, // Grants +10 seconds (5000/500 * 1)
            dur = 5 * time.Second, 
            // Total becomes 35s. Absolute max is 40s. 
            // Allowed remaining is 5s. 
            // Timeout (20 - 5 + 10 = 25) gets clamped to 5s.
            output = { transferred = 5000, total = 35 * time.Second, max = -1, timeout = 5 * time.Second },
        },
        {
            description = "7. Immediate transfer (dur=0) skips rate check and grants fractional time",
            input_budget = { transferred = 0, total = 0, max = -1, timeout = 20 * time.Second },
            input_limits = { max_size = 0, min = 20 * time.Second, max = 0, min_rate = 500, rate_add = time.Second },
            transferred = 100,
            dur = 0,
            // rate_add is added cleanly: (100 / 500) * 1s = 200ms
            output = { transferred = 100, total = 0, max = -1, timeout = 20 * time.Second + 200 * time.Millisecond },
        },
        {
            description = "8. Absolute max perfectly exhausted (timeout goes to 0)",
            input_budget = { transferred = 0, total = 38 * time.Second, max = -1, timeout = 5 * time.Second },
            input_limits = { max_size = 0, min = 0, max = 40 * time.Second, min_rate = 0, rate_add = 0 },
            transferred = 1000,
            dur = 2 * time.Second,
            // Total hits 40s (max allowed). Remaining allowed is 0.
            output = { transferred = 1000, total = 40 * time.Second, max = -1, timeout = 0 },
        },
	}

	for &c in cases {
		c.input_budget.limits = &c.input_limits
		c.output.limits       = &c.input_limits
		http.budget_update(&c.input_budget, c.transferred, c.dur)
		if !testing.expect_value(t, c.input_budget, c.output) {
			log.errorf("FAIL: %s", c.description)
		}
	}
}

@(test)
test_server_options_default_and_no_limits :: proc(t: ^testing.T) {
	default_server := http.make_server({})
	testing.expect_value(t, http.DEFAULT_HEADERS_LIMITS.max_size, 64 * mem.Kilobyte)
	testing.expect_value(t, http.DEFAULT_BODY_LIMITS.max_size, 10 * mem.Megabyte)
	testing.expect_value(t, default_server.opts.request_limits, http.DEFAULT_HEADERS_LIMITS)
	testing.expect_value(t, default_server.opts.body_limits, http.DEFAULT_BODY_LIMITS)
	testing.expect_value(t, default_server.opts.response_limits, http.DEFAULT_SEND_LIMITS)
	testing.expect_value(t, default_server.opts.max_headers, http.DEFAULT_MAX_HEADERS)

	custom_limits := http.Limits{max_size = 1234, min = 5 * time.Second}
	unlimited_server := http.make_server({
		request_limits  = custom_limits,
		body_limits     = http.NO_LIMITS,
		response_limits = http.NO_LIMITS,
	})
	testing.expect_value(t, unlimited_server.opts.request_limits, custom_limits)
	testing.expect_value(t, unlimited_server.opts.body_limits, http.NO_LIMITS)
	testing.expect_value(t, unlimited_server.opts.response_limits, http.NO_LIMITS)

	b: http.Budget
	http.budget_init(&b, &http.NO_LIMITS)
	testing.expect_value(t, b.max, -1)
	testing.expect_value(t, b.timeout, time.Duration(-1))
	testing.expect(t, !http.budget_is_exhausted(b))

	http.budget_update(&b, 1_000_000, 10 * time.Minute)
	testing.expect_value(t, b.max, -1)
	testing.expect_value(t, b.timeout, time.Duration(-1))
	testing.expect(t, !http.budget_is_exhausted(b))
}

@(test)
test_per_request_and_response_limits_overrides :: proc(t: ^testing.T) {
	// 1. Fresh state with pointer overload (zero-alloc, points directly to caller's Limits).
	req: http.Request
	l_fresh := http.Limits{
		max_size = 1000,
		min      = 10 * time.Second,
		max      = 30 * time.Second,
		min_rate = 500,
		rate_add = time.Second,
	}
	http.request_set_limits(&req, &l_fresh)
	testing.expect_value(t, req.budget.limits, &l_fresh)
	testing.expect_value(t, req.budget.limits^, l_fresh)
	testing.expect_value(t, req.budget.max, 1000)
	testing.expect_value(t, req.budget.timeout, 10 * time.Second)

	res: http.Response
	http.response_set_limits(&res, &l_fresh)
	testing.expect_value(t, res.budget.limits, &l_fresh)
	testing.expect_value(t, res.budget.limits^, l_fresh)
	testing.expect_value(t, res.budget.max, 1000)
	testing.expect_value(t, res.budget.timeout, 10 * time.Second)

	// 2. Partially transferred state accounts for transferred bytes & elapsed duration.
	req.budget.transferred = 1000
	req.budget.total = 3 * time.Second
	l_override := http.Limits{
		max_size = 5000,
		min      = 10 * time.Second,
		max      = 20 * time.Second,
		min_rate = 500,
		rate_add = time.Second,
	}
	http.request_set_limits(&req, &l_override)
	testing.expect_value(t, req.budget.limits, &l_override)
	// max = 5000 - 1000 = 4000
	testing.expect_value(t, req.budget.max, 4000)
	// timeout = 10s - 3s + (1000 / 500) * 1s = 9s (< max - total = 17s)
	testing.expect_value(t, req.budget.timeout, 9 * time.Second)

	// Overriding to a smaller max_size than already transferred floors max at 0.
	l_small := http.Limits{max_size = 500, min = 5 * time.Second, max = 4 * time.Second}
	res.budget.transferred = 600
	res.budget.total = 5 * time.Second
	http.response_set_limits(&res, &l_small)
	testing.expect_value(t, res.budget.limits, &l_small)
	testing.expect_value(t, res.budget.max, 0)
	testing.expect_value(t, res.budget.timeout, time.Duration(0))

	// Overriding to NO_LIMITS via pointer clears both limits regardless of prior usage.
	l_unlimited := http.NO_LIMITS
	http.request_set_limits(&req, &l_unlimited)
	testing.expect_value(t, req.budget.max, -1)
	testing.expect_value(t, req.budget.timeout, time.Duration(-1))

	// 3. Body size checks honor request_set_limits overrides in both directions.
	s := http.make_server({})

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	setup_body_conn :: proc(t: ^testing.T, c: ^http.Connection, limits: ^http.Limits, clen_str, payload: string) {
		c^ = http.Connection{
			transaction_arena = http.get_arena(nil),
			temp_arena        = http.get_arena(nil),
		}
		c.transaction_arena.c = c
		c.temp_arena.c = c

		tx_alloc := http.transaction_allocator(c)
		c._vars.allocator = tx_alloc
		c.req.headers.allocator = tx_alloc
		c.res.headers.allocator = tx_alloc
		c.res._buf.allocator = tx_alloc
		c.scanner.c = c
		c.scanner.allocator = &c.transaction_arena

		c.res._state = .Handling
		c.res.budget.max = 0
		c.res._sends = 1

		http.budget_reset(&c.req.budget, limits)

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

	// Loosening: initial tight limit (8 bytes) lifted via request_set_limits allows 16-byte body.
	{
		c: http.Connection
		tight := http.Limits{max_size = 8}
		setup_body_conn(t, &c, &tight, "16", "0123456789abcdef")
		defer cleanup_body_conn(&c)

		req_unlimited := http.NO_LIMITS
		http.request_set_limits(&c.req, &req_unlimited)
		testing.expect_value(t, c.req.budget.limits, &req_unlimited)
		testing.expect_value(t, c.req.budget.max, -1)

		res_custom := http.Limits{max_size = 42, min = 3 * time.Second}
		http.response_set_limits(&c.res, &res_custom)
		testing.expect_value(t, c.res.budget.limits, &res_custom)
		testing.expect_value(t, c.res.budget.max, 42)
		testing.expect_value(t, c.res.budget.timeout, 3 * time.Second)

		chk := http.context_add(&c.ctx, Body_Check{t = t})
		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {
			chk := http.context_get(ctx, Body_Check)
			chk.len += len(body)
			if !is_partial {
				chk.done = true
			}
		})
		testing.expect(t, chk.done)
		testing.expect_value(t, chk.len, 16)
	}

	// Tightening: DEFAULT_BODY_LIMITS reduced via request_set_limits rejects 16-byte body with 413.
	{
		c: http.Connection
		default_body := http.DEFAULT_BODY_LIMITS
		setup_body_conn(t, &c, &default_body, "16", "")
		defer cleanup_body_conn(&c)

		req_tight := http.Limits{max_size = 8}
		http.request_set_limits(&c.req, &req_tight)
		testing.expect_value(t, c.req.budget.limits, &req_tight)
		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect(t, c.res._state == .Error)
	}
}
