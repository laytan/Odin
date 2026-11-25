package tests_http2

import http "core:http2"
import "core:testing"
import "core:time"

@(test)
test_progression_initialization :: proc(t: ^testing.T) {
	q := http.Quota{max_size = 100, min = 2 * time.Second, max = 10 * time.Second}
	p: http.Progression
	http.progression_init(&p, &q)

	testing.expect_value(t, p.quota, &q)
	testing.expect_value(t, p.max, 100)
	testing.expect_value(t, p.timeout, 2 * time.Second)
	testing.expect_value(t, http.progression_max_transfer(p, 200), 100)
	testing.expect_value(t, http.progression_next_timeout(p), 2 * time.Second)
}

@(test)
test_progression_unlimited :: proc(t: ^testing.T) {
	p: http.Progression
	http.progression_reset(&p, nil)

	testing.expect_value(t, p.max, -1)
	testing.expect_value(t, p.timeout, -1)
	testing.expect_value(t, http.progression_max_transfer(p, 200), 200)
	testing.expect(t, !http.progression_is_exhausted(p), "unlimited progression should not be exhausted")
}

@(test)
test_progression_updates_bytes_and_time :: proc(t: ^testing.T) {
	q := http.Quota{max_size = 100, min = 2 * time.Second, max = 5 * time.Second, min_rate = 500, rate_add = time.Second}
	p: http.Progression
	http.progression_init(&p, &q)

	http.progression_update(&p, 500, time.Second)

	testing.expect_value(t, p.transferred, 500)
	testing.expect_value(t, p.total, time.Second)
	testing.expect_value(t, p.max, 0)
	testing.expect_value(t, p.timeout, 2 * time.Second)
	testing.expect(t, http.progression_is_exhausted(p), "byte limit should be exhausted")
}

@(test)
test_progression_enforces_slow_rate :: proc(t: ^testing.T) {
	q := http.Quota{min = 2 * time.Second, min_rate = 500}
	p: http.Progression
	http.progression_init(&p, &q)

	http.progression_update(&p, 499, time.Second)

	testing.expect_value(t, p.timeout, time.Duration(0))
	testing.expect(t, http.progression_is_exhausted(p), "slow progression should be exhausted")
}

@(test)
test_progression_enforces_absolute_timeout :: proc(t: ^testing.T) {
	q := http.Quota{min = 2 * time.Second, max = 3 * time.Second, min_rate = 500, rate_add = time.Second}
	p: http.Progression
	http.progression_init(&p, &q)

	http.progression_update(&p, 1000, 2 * time.Second)

	testing.expect_value(t, p.timeout, time.Second)
	http.progression_update(&p, 500, time.Second)
	testing.expect_value(t, p.timeout, time.Duration(0))
}
