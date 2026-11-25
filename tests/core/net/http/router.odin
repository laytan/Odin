package test_core_net_http

import "core:mem"
import "core:strings"
import "core:testing"

import http "core:http2"

@(test)
test_route_conflicts :: proc(t: ^testing.T) {
	Case :: struct {
		a, b:     string,
		conflict: bool,
	}

	cases := [?]Case{
		{"/a/b",          "/a/b",              true},
		{"/a/:param",     "/a/:param2",        true},
		{"/a/b",          "/a/:param",         false},
		{"/a/b/c",        "/a/b/:param",       false},
		{"/a/:param",     "/:param/:param2",   false},
		{"/a/:param",     "/:param/b",         true},
		{"/a/:param/c",   "/:param/b/c",       true},
		{"/a/b/:param",   "/a/c/:param",       false},
		{"/a/:param",     "/b/:param",         false},
		{"/a/b",          "/a/b/c",            false},
		{"/:param",       "/:param/:param2",   false},
		{"/a/:param/c",   "/:param/b/:param",  false},
		{"/a/b/c",        "/a/:param/:param2", false},
		{"/:param",       "/users/:id",        false},
		{"/:param/b",     "/a/:param",         true},
		{"/v1/:id/name",  "/v1/:id/type",      false},
		{"/apple/:param", "/banana/:param",    false},
		{"/a/:year/11",   "/a/year/:month",    true},
		{"/static/*",     "/static/*",         true},
		{"/static",       "/static/*",         false},
		{"/*",            "/*",                true},
		{"*",             "*",                 true},
	}

	noop := proc(ctx: ^http.Ctx) {}

	for tc, i in cases {
		tt: http._Route_Trie
		tt.segments.allocator = context.allocator
		defer http._route_trie_destroy(tt, context.allocator)

		http._route_trie_add(&tt, tc.a, {noop}, context.allocator)
		_, got_conflict := http._route_trie_check_conflicts(tt, tc.b).?
		testing.expectf(t, got_conflict == tc.conflict, "%d: routes %q and %q expected conflict=%v, got %v", i, tc.a, tc.b, tc.conflict, got_conflict)
	}
}

@(test)
test_head_method_preserved_and_router_fallback :: proc(t: ^testing.T) {
	// 1. Direct handler on Server_Options.handlers sees .Head (not rewritten to .Get).
	{
		Direct_State :: struct {
			called:     bool,
			method:     http.Method,
			wants_body: bool,
		}

		state: Direct_State
		h := http.handler(&state, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Direct_State)(user_data)
			st.called = true
			st.method = ctx.req.line.method
			st.wants_body = http.wants_body(ctx)

			ctx.res.budget.max = 0
			ctx.res._sends = 1
			http.write_response_heading(ctx)
			ctx.res._state = .Sending
			http.respond(ctx)
		})

		env: Test_Env
		test_env_init(&env, opts = {handlers = {h}})
		defer test_env_destroy(&env)

		c: http.Connection
		test_conn_init(t, &c, &env, payload = "HEAD /direct HTTP/1.1\r\nHost: localhost\r\n\r\n", mock_send = true, init_budgets = false)
		defer test_conn_destroy(&c)

		http._serve_connection(&c)
		testing.expect(t, state.called, "expected direct handler to run")
		testing.expect_value(t, state.method, http.Method.Head)
		testing.expect(t, !state.wants_body, "expected wants_body to be false for HEAD")
	}

	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	// 2. Router falls back from .Head to .Get (before route_all), preserves .Head, and extracts :param.
	{
		Fallback_State :: struct {
			get_called: bool,
			all_called: bool,
			method:     http.Method,
			wants_body: bool,
			param_buf:  [16]byte,
			param_len:  int,
		}

		state: Fallback_State
		r: http.Router
		defer http.router_destroy(r)

		http.route_get(&r, "/users/:id", http.handler(&state, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Fallback_State)(user_data)
			st.get_called = true
			st.method = ctx.req.line.method
			st.wants_body = http.wants_body(ctx)
			id := http.route_param(http.route_params(ctx), "id")
			st.param_len = copy(st.param_buf[:], id)

			ctx.res.budget.max = 0
			ctx.res._sends = 1
			http.respond_bytes(ctx, transmute([]byte)string("hello"))
		}))
		http.route_all(&r, "/*", http.handler(&state, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Fallback_State)(user_data)
			st.all_called = true
			ctx.res.budget.max = 0
			ctx.res._sends = 1
			http.respond(ctx)
		}))

		env.s.opts.handlers = {http.router(&r)}

		c: http.Connection
		test_conn_init(t, &c, &env, payload = "HEAD /users/42 HTTP/1.1\r\nHost: localhost\r\n\r\n", mock_send = true, init_budgets = false)
		defer test_conn_destroy(&c)

		http._serve_connection(&c)
		testing.expect(t, state.get_called, "expected HEAD to fall back to GET route")
		testing.expect(t, !state.all_called, "expected HEAD fallback to match GET route before route_all")
		testing.expect_value(t, state.method, http.Method.Head)
		testing.expect(t, !state.wants_body, "expected wants_body to be false for HEAD")
		testing.expect_value(t, string(state.param_buf[:state.param_len]), "42")
		testing.expect(t, strings.contains(string(c.res._buf[:]), "Content-Length: 5\r\n"), "expected Content-Length: 5 header")
	}

	// 3. Explicit route_head takes precedence over route_get for HEAD requests.
	{
		Custom_State :: struct {
			head_called: bool,
			get_called:  bool,
			head_method: http.Method,
			get_method:  http.Method,
		}

		state: Custom_State
		r: http.Router
		defer http.router_destroy(r)

		http.route_head(&r, "/custom", http.handler(&state, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Custom_State)(user_data)
			st.head_called = true
			st.head_method = ctx.req.line.method
			ctx.res.budget.max = 0
			ctx.res._sends = 1
			http.respond(ctx)
		}))
		http.route_get(&r, "/custom", http.handler(&state, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Custom_State)(user_data)
			st.get_called = true
			st.get_method = ctx.req.line.method
			ctx.res.budget.max = 0
			ctx.res._sends = 1
			http.respond(ctx)
		}))

		env.s.opts.handlers = {http.router(&r)}

		{
			c: http.Connection
			test_conn_init(t, &c, &env, payload = "HEAD /custom HTTP/1.1\r\nHost: localhost\r\n\r\n", mock_send = true, init_budgets = false)
			defer test_conn_destroy(&c)

			http._serve_connection(&c)
			testing.expect(t, state.head_called, "expected explicit route_head handler")
			testing.expect(t, !state.get_called, "expected HEAD not to invoke route_get when route_head exists")
			testing.expect_value(t, state.head_method, http.Method.Head)
		}

		state = {}
		{
			c: http.Connection
			test_conn_init(t, &c, &env, payload = "GET /custom HTTP/1.1\r\nHost: localhost\r\n\r\n", mock_send = true, init_budgets = false)
			defer test_conn_destroy(&c)

			http._serve_connection(&c)
			testing.expect(t, state.get_called, "expected GET handler")
			testing.expect(t, !state.head_called, "expected GET not to invoke route_head")
			testing.expect_value(t, state.get_method, http.Method.Get)
		}
	}

	// 4. Nested sub-router mounted via route_all("/api/*", ...) falls back HEAD -> GET in sub-router.
	{
		Nested_State :: struct {
			called: bool,
			method: http.Method,
		}

		state: Nested_State
		api: http.Router
		defer http.router_destroy(api)
		http.route_get(&api, "/items", http.handler(&state, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Nested_State)(user_data)
			st.called = true
			st.method = ctx.req.line.method
			ctx.res.budget.max = 0
			ctx.res._sends = 1
			http.respond(ctx)
		}))

		root: http.Router
		defer http.router_destroy(root)
		http.route_all(&root, "/api/*", http.router(&api))

		env.s.opts.handlers = {http.router(&root)}

		c: http.Connection
		test_conn_init(t, &c, &env, payload = "HEAD /api/items HTTP/1.1\r\nHost: localhost\r\n\r\n", mock_send = true, init_budgets = false)
		defer test_conn_destroy(&c)

		http._serve_connection(&c)
		testing.expect(t, state.called, "expected nested sub-router GET route to handle HEAD")
		testing.expect_value(t, state.method, http.Method.Head)
	}

	// 5. Router with only route_post returns 404 Not Found on HEAD.
	{
		r: http.Router
		defer http.router_destroy(r)
		http.route_post(&r, "/only-post", proc(ctx: ^http.Ctx) {})

		c: http.Connection
		test_conn_init(t, &c, &env, mock_send = true, init_budgets = false)
		defer test_conn_destroy(&c)
		c.req.line = {method = .Head, target = "/only-post", version = {1, 1}}

		http.handle({http.router(&r)}, &c.ctx)
		testing.expect_value(t, c.res.status, http.Status.Not_Found)
	}
}

@(test)
test_router_target_and_suffix :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	Capture :: struct {
		matched:    string,
		target_buf: [128]byte,
		target_len: int,
		suffix_buf: [128]byte,
		suffix_len: int,
		id_buf:     [32]byte,
		id_len:     int,
	}

	dispatch :: proc(t: ^testing.T, env: ^Test_Env, r: ^http.Router, raw_target: string, cap: ^Capture) {
		cap^ = {}
		c: http.Connection
		test_conn_init(t, &c, env, mock_send = true, init_budgets = false)
		defer test_conn_destroy(&c)
		c.req.line = {method = .Get, target = raw_target, version = {1, 1}}
		http.handle({http.router(r)}, &c.ctx)
	}

	// 1. Prefix wildcard (/static/*) and bare prefix (/static).
	{
		cap: Capture
		r: http.Router
		defer http.router_destroy(r)

		http.route_get(&r, "/static", http.handler(&cap, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Capture)(user_data)
			st.matched    = "bare"
			st.target_len = copy(st.target_buf[:], http.route_target(ctx))
			st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
		}))
		http.route_get(&r, "/static/*", http.handler(&cap, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Capture)(user_data)
			st.matched    = "wild"
			st.target_len = copy(st.target_buf[:], http.route_target(ctx))
			st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
		}))

		Case :: struct {
			raw, matched, target, suffix: string,
		}
		for tc in ([?]Case{
			{"/static",                  "bare", "/static",                 ""},
			{"/static/",                 "wild", "/static/",                "/"},
			{"/static/a",                "wild", "/static/a",               "/a"},
			{"/static/a/b/c?x=1",        "wild", "/static/a/b/c",           "/a/b/c"},
			{"/static/hello%20world.txt","wild", "/static/hello world.txt", "/hello world.txt"},
		}) {
			dispatch(t, &env, &r, tc.raw, &cap)
			testing.expect_value(t, cap.matched, tc.matched)
			testing.expect_value(t, string(cap.target_buf[:cap.target_len]), tc.target)
			testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), tc.suffix)
		}
	}

	// 2. Root wildcard (/*) without explicit "/" vs with explicit "/".
	{
		cap: Capture
		r: http.Router
		defer http.router_destroy(r)

		http.route_get(&r, "/*", http.handler(&cap, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Capture)(user_data)
			st.matched    = "root-wild"
			st.target_len = copy(st.target_buf[:], http.route_target(ctx))
			st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
		}))

		dispatch(t, &env, &r, "/", &cap)
		testing.expect_value(t, cap.matched, "root-wild")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/")

		dispatch(t, &env, &r, "/file.txt", &cap)
		testing.expect_value(t, cap.matched, "root-wild")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/file.txt")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/file.txt")

		http.route_get(&r, "/", http.handler(&cap, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Capture)(user_data)
			st.matched    = "root-exact"
			st.target_len = copy(st.target_buf[:], http.route_target(ctx))
			st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
		}))

		dispatch(t, &env, &r, "/", &cap)
		testing.expect_value(t, cap.matched, "root-exact")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "")
	}

	// 3. Bare wildcard (*).
	{
		cap: Capture
		r: http.Router
		defer http.router_destroy(r)

		http.route_get(&r, "*", http.handler(&cap, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Capture)(user_data)
			st.matched    = "star"
			st.target_len = copy(st.target_buf[:], http.route_target(ctx))
			st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
		}))

		dispatch(t, &env, &r, "/", &cap)
		testing.expect_value(t, cap.matched, "star")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/")

		dispatch(t, &env, &r, "/foo/bar", &cap)
		testing.expect_value(t, cap.matched, "star")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/foo/bar")
	}

	// 4. Nested sub-router mounted at /api/*.
	{
		cap: Capture
		api: http.Router
		defer http.router_destroy(api)

		http.route_get(&api, "/users/:id", http.handler(&cap, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Capture)(user_data)
			st.matched    = "api-user"
			st.target_len = copy(st.target_buf[:], http.route_target(ctx))
			st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
			st.id_len     = copy(st.id_buf[:],     http.route_param(http.route_params(ctx), "id"))
		}))
		http.route_get(&api, "/files/*", http.handler(&cap, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Capture)(user_data)
			st.matched    = "api-files"
			st.target_len = copy(st.target_buf[:], http.route_target(ctx))
			st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
		}))

		root: http.Router
		defer http.router_destroy(root)
		http.route_all(&root, "/api/*", http.router(&api))

		dispatch(t, &env, &root, "/api/users/42", &cap)
		testing.expect_value(t, cap.matched, "api-user")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/api/users/42")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "")
		testing.expect_value(t, string(cap.id_buf[:cap.id_len]), "42")

		dispatch(t, &env, &root, "/api/files/dir/a.txt", &cap)
		testing.expect_value(t, cap.matched, "api-files")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/api/files/dir/a.txt")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/dir/a.txt")
	}
}

@(test)
test_subrouter_middleware_user_data_preserved :: proc(t: ^testing.T) {
	Mw_State :: struct {
		orig_user_data: rawptr,
		inner_called:   bool,
		defer_called:   bool,
		after_ud_ok:    bool,
		defer_ud_ok:    bool,
	}

	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	st: Mw_State
	st.orig_user_data = &st

	api: http.Router
	defer http.router_destroy(api)
	http.route_get(&api, "/items", http.handler(&st, proc(user_data: rawptr, ctx: ^http.Ctx) {
		st := (^Mw_State)(user_data)
		st.inner_called = true
		ctx.res.status  = .OK
		http.write_response_heading(ctx)
		ctx.res._state = .Sent
	}))

	mw := http.handler(&st, proc(user_data: rawptr, ctx: ^http.Ctx, next: []http.Handler) {
		st := (^Mw_State)(user_data)

		_ = http.context_add(ctx, user_data)
		_ = http.response_defer(ctx, proc(ctx: ^http.Ctx) {
			ud := http.context_get(ctx, rawptr)^
			st := (^Mw_State)(ud)
			st.defer_called = true
			st.defer_ud_ok  = ud == st.orig_user_data
		})

		http.handle(next, ctx)

		st.after_ud_ok = user_data == st.orig_user_data
	})

	root: http.Router
	defer http.router_destroy(root)
	http.route_all(&root, "/api/*", mw, http.router(&api))

	c: http.Connection
	test_conn_init(t, &c, &env, init_budgets = false)
	defer test_conn_destroy(&c)

	c.scanner.is_pumping    = true
	c.res._state            = .Handling
	c.res.budget.max        = 0
	c.res._sends            = 0
	c.req.has_consumed_body = true
	c.req.line = {method = .Get, target = "/api/items", version = {1, 1}}

	http.handle({http.router(&root)}, &c.ctx)
	http._check_send_done(&c)

	testing.expect(t, st.inner_called, "expected inner sub-router route to execute")
	testing.expect(t, st.defer_called, "expected response_defer to execute")
	testing.expect(t, st.after_ud_ok, "expected middleware user_data preserved after sub-router dispatch")
	testing.expect(t, st.defer_ud_ok, "expected middleware user_data preserved in response_defer")
}

@(test)
test_route_middleware_chain_order_short_circuit_and_cleanup :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	Chain_Log :: struct {
		events: [8]string,
		count:  int,
		block:  bool,
	}

	record :: proc(log_st: ^Chain_Log, label: string) {
		log_st.events[log_st.count] = label
		log_st.count += 1
	}

	mw1 := proc(user_data: rawptr, ctx: ^http.Ctx, next: []http.Handler) {
		st := (^Chain_Log)(user_data)
		record(st, "mw1:before")
		http.handle(next, ctx)
		record(st, "mw1:after")
	}
	mw2 := proc(user_data: rawptr, ctx: ^http.Ctx, next: []http.Handler) {
		st := (^Chain_Log)(user_data)
		record(st, "mw2:before")
		if st.block {
			ctx.res.status = .Forbidden
			http.write_response_heading(ctx)
			ctx.res._state = .Sent
			return
		}
		http.handle(next, ctx)
		record(st, "mw2:after")
	}
	endpoint := proc(user_data: rawptr, ctx: ^http.Ctx) {
		st := (^Chain_Log)(user_data)
		record(st, "endpoint")
		ctx.res.status = .OK
		http.write_response_heading(ctx)
		ctx.res._state = .Sent
	}

	track: mem.Tracking_Allocator
	test_tracking_init(&track)
	defer mem.tracking_allocator_destroy(&track)

	st: Chain_Log
	{
		r := http.make_router(mem.tracking_allocator(&track))
		defer http.router_destroy(r)

		http.route_get(&r, "/chain", http.handler(&st, mw1), http.handler(&st, mw2), http.handler(&st, endpoint))
		http.route_all(&r, "/prefix/*", http.handler(&st, mw1), http.handler(&st, endpoint))

		run_req :: proc(t: ^testing.T, env: ^Test_Env, r: ^http.Router, target: string) -> http.Status {
			c: http.Connection
			test_conn_init(t, &c, env, mock_send = true, init_budgets = false)
			defer test_conn_destroy(&c)
			c.req.has_consumed_body = true
			c.req.line = {method = .Get, target = target, version = {1, 1}}

			http.handle({http.router(r)}, &c.ctx)
			return c.res.status
		}

		// 1. Full middleware chain runs in order (before -> inner -> after).
		testing.expect_value(t, run_req(t, &env, &r, "/chain"), http.Status.OK)
		expect_slice(t, st.events[:st.count], []string{"mw1:before", "mw2:before", "endpoint", "mw2:after", "mw1:after"})

		// 2. Short-circuiting in mw2 skips endpoint and mw2:after while mw1:after still runs.
		st = {block = true}
		testing.expect_value(t, run_req(t, &env, &r, "/chain"), http.Status.Forbidden)
		expect_slice(t, st.events[:st.count], []string{"mw1:before", "mw2:before", "mw1:after"})

		// 3. Prefix wildcard route also runs multi-handler chain.
		st = {}
		testing.expect_value(t, run_req(t, &env, &r, "/prefix/hello"), http.Status.OK)
		expect_slice(t, st.events[:st.count], []string{"mw1:before", "endpoint", "mw1:after"})
	}

	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
