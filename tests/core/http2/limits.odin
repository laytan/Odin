package tests_http2

import http "core:http2"
import "core:testing"
import "core:time"

@(test)
test_budget_initialization :: proc(t: ^testing.T) {
	l := http.Limits{max_size = 100, min = 2 * time.Second, max = 10 * time.Second}
	b: http.Budget
	http.budget_init(&b, &l)

	testing.expect_value(t, b.limits, &l)
	testing.expect_value(t, b.max, 100)
	testing.expect_value(t, b.timeout, 2 * time.Second)
	testing.expect_value(t, http.budget_max_transfer(b, 200), 100)
	testing.expect_value(t, http.budget_next_timeout(b), 2 * time.Second)
}

@(test)
test_budget_unlimited :: proc(t: ^testing.T) {
	b: http.Budget
	http.budget_reset(&b, nil)

	testing.expect_value(t, b.max, -1)
	testing.expect_value(t, b.timeout, -1)
	testing.expect_value(t, http.budget_max_transfer(b, 200), 200)
	testing.expect(t, !http.budget_is_exhausted(b), "unlimited budget should not be exhausted")
}

@(test)
test_budget_updates_bytes_and_time :: proc(t: ^testing.T) {
	l := http.Limits{max_size = 100, min = 2 * time.Second, max = 5 * time.Second, min_rate = 500, rate_add = time.Second}
	b: http.Budget
	http.budget_init(&b, &l)

	http.budget_update(&b, 500, time.Second)

	testing.expect_value(t, b.transferred, 500)
	testing.expect_value(t, b.total, time.Second)
	testing.expect_value(t, b.max, 0)
	testing.expect_value(t, b.timeout, 2 * time.Second)
	testing.expect(t, http.budget_is_exhausted(b), "byte limit should be exhausted")
}

@(test)
test_budget_enforces_slow_rate :: proc(t: ^testing.T) {
	l := http.Limits{min = 2 * time.Second, min_rate = 500}
	b: http.Budget
	http.budget_init(&b, &l)

	http.budget_update(&b, 499, time.Second)

	testing.expect_value(t, b.timeout, time.Duration(0))
	testing.expect(t, http.budget_is_exhausted(b), "slow budget should be exhausted")
}

@(test)
test_budget_enforces_absolute_timeout :: proc(t: ^testing.T) {
	l := http.Limits{min = 2 * time.Second, max = 3 * time.Second, min_rate = 500, rate_add = time.Second}
	b: http.Budget
	http.budget_init(&b, &l)

	http.budget_update(&b, 1000, 2 * time.Second)

	testing.expect_value(t, b.timeout, time.Second)
	http.budget_update(&b, 500, time.Second)
	testing.expect_value(t, b.timeout, time.Duration(0))
}
