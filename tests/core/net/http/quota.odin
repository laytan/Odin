package test_core_net_http

import "core:time"
import "core:log"
import "core:testing"
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
	testing.expect_value(t, default_server.opts.request_quota, http.DEFAULT_HEADERS_QUOTA)
	testing.expect_value(t, default_server.opts.body_quota, http.DEFAULT_BODY_QUOTA)
	testing.expect_value(t, default_server.opts.response_quota, http.DEFAULT_SEND_QUOTA)

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
