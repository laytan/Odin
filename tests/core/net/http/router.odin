package test_core_net_http

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import http "core:http2"

@(test)
test_head_method_preserved_and_router_fallback :: proc(t: ^testing.T) {
	http.headers_init_hash_secret()

	setup_conn :: proc(t: ^testing.T, c: ^http.Connection, payload: string) {
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
		c.res.progress.max = 0
		c.res._sends = 1

		if len(payload) > 0 {
			buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
			testing.expect_value(t, buf_err, nil)
			c.scanner.buf = buf
			c.scanner.write_head = copy(buf, payload)
		}
	}

	cleanup_conn :: proc(c: ^http.Connection) {
		http.temp_allocator_destroy(c)
		http.transaction_allocator_destroy(c)
	}

	// 1. Direct handler on Server_Options.handler sees .Head (not rewritten to .Get).
	{
		Direct_State :: struct {
			called:     bool,
			method:     http.Method,
			wants_body: bool,
		}

		state: Direct_State
		handler := http.Handler{
			user_data = &state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Direct_State)(h.user_data)
				st.called = true
				st.method = ctx.req.line.method
				st.wants_body = http.wants_body(&ctx.req)

				ctx.res.progress.max = 0
				ctx.res._sends = 1
				http.write_response_heading(&ctx.res)
				ctx.res._state = .Sending
				http.respond(&ctx.res)
			},
		}

		s := http.make_server({handler = handler})
		err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
		testing.expect_value(t, err, nil)
		defer virtual.arena_destroy(&s.temp_allocator_backing)

		thread := http.Server_Thread{s = &s, id = 1}
		prev_td := http.td
		http.td = &thread
		defer http.td = prev_td
		defer http._server_thread_free_arenas_destroy(&thread)

		c: http.Connection
		setup_conn(t, &c, "HEAD /direct HTTP/1.1\r\nHost: localhost\r\n\r\n")
		defer cleanup_conn(&c)

		http._serve_connection(&c)
		testing.expect(t, state.called, "expected direct handler to run")
		testing.expect_value(t, state.method, http.Method.Head)
		testing.expect(t, !state.wants_body, "expected wants_body to be false for HEAD")
	}

	s := http.make_server({})
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

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

		http.route_get(&r, "/users/:id", http.Handler{
			user_data = &state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Fallback_State)(h.user_data)
				st.get_called = true
				st.method = ctx.req.line.method
				st.wants_body = http.wants_body(&ctx.req)
				id := http.route_param(http.route_params(ctx), "id")
				st.param_len = copy(st.param_buf[:], id)

				ctx.res.progress.max = 0
				ctx.res._sends = 1
				http.respond_bytes(&ctx.res, transmute([]byte)string("hello"))
			},
		})
		http.route_all(&r, "/*", http.Handler{
			user_data = &state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Fallback_State)(h.user_data)
				st.all_called = true
				ctx.res.progress.max = 0
				ctx.res._sends = 1
				http.respond(&ctx.res)
			},
		})

		s.opts.handler = http.router(&r)

		c: http.Connection
		setup_conn(t, &c, "HEAD /users/42 HTTP/1.1\r\nHost: localhost\r\n\r\n")
		defer cleanup_conn(&c)

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

		http.route_head(&r, "/custom", http.Handler{
			user_data = &state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Custom_State)(h.user_data)
				st.head_called = true
				st.head_method = ctx.req.line.method
				ctx.res.progress.max = 0
				ctx.res._sends = 1
				http.respond(&ctx.res)
			},
		})
		http.route_get(&r, "/custom", http.Handler{
			user_data = &state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Custom_State)(h.user_data)
				st.get_called = true
				st.get_method = ctx.req.line.method
				ctx.res.progress.max = 0
				ctx.res._sends = 1
				http.respond(&ctx.res)
			},
		})

		s.opts.handler = http.router(&r)

		{
			c: http.Connection
			setup_conn(t, &c, "HEAD /custom HTTP/1.1\r\nHost: localhost\r\n\r\n")
			defer cleanup_conn(&c)

			http._serve_connection(&c)
			testing.expect(t, state.head_called, "expected explicit route_head handler")
			testing.expect(t, !state.get_called, "expected HEAD not to invoke route_get when route_head exists")
			testing.expect_value(t, state.head_method, http.Method.Head)
		}

		state = {}
		{
			c: http.Connection
			setup_conn(t, &c, "GET /custom HTTP/1.1\r\nHost: localhost\r\n\r\n")
			defer cleanup_conn(&c)

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
		http.route_get(&api, "/items", http.Handler{
			user_data = &state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Nested_State)(h.user_data)
				st.called = true
				st.method = ctx.req.line.method
				ctx.res.progress.max = 0
				ctx.res._sends = 1
				http.respond(&ctx.res)
			},
		})

		root: http.Router
		defer http.router_destroy(root)
		http.route_all(&root, "/api/*", http.router(&api))

		s.opts.handler = http.router(&root)

		c: http.Connection
		setup_conn(t, &c, "HEAD /api/items HTTP/1.1\r\nHost: localhost\r\n\r\n")
		defer cleanup_conn(&c)

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
		setup_conn(t, &c, "")
		defer cleanup_conn(&c)
		c.req.line = {
			method  = .Head,
			target  = "/only-post",
			version = {1, 1},
		}

		rh := http.router(&r)
		rh.handle(&rh, &c.ctx)
		testing.expect_value(t, c.res.status, http.Status.Not_Found)
	}
}

@(test)
test_router_target_and_suffix :: proc(t: ^testing.T) {
	http.headers_init_hash_secret()

	s := http.make_server({})
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	Capture :: struct {
		matched:    string,
		target_buf: [128]byte,
		target_len: int,
		suffix_buf: [128]byte,
		suffix_len: int,
		id_buf:     [32]byte,
		id_len:     int,
	}

	dispatch :: proc(t: ^testing.T, r: ^http.Router, raw_target: string, cap: ^Capture) {
		cap^ = {}

		c: http.Connection
		c.transaction_arena = http.get_arena(nil)
		c.temp_arena        = http.get_arena(nil)
		c.transaction_arena.c = &c
		c.temp_arena.c        = &c
		defer {
			http.temp_allocator_destroy(&c)
			http.transaction_allocator_destroy(&c)
		}

		tx_alloc := http.transaction_allocator(&c)
		c._vars.allocator        = tx_alloc
		c.req.headers.allocator = tx_alloc
		c.res.headers.allocator = tx_alloc
		c.res._buf.allocator     = tx_alloc
		c.scanner.c             = &c
		c.scanner.allocator     = &c.transaction_arena
		c.res._state             = .Handling
		c.res.progress.max      = 0
		c.res._sends             = 1
		c.req.line = {
			method  = .Get,
			target  = raw_target,
			version = {1, 1},
		}

		rh := http.router(r)
		rh.handle(&rh, &c.ctx)
	}

	// 1. Prefix wildcard (/static/*) and bare prefix (/static).
	{
		cap: Capture
		r: http.Router
		defer http.router_destroy(r)

		http.route_get(&r, "/static", http.Handler{
			user_data = &cap,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Capture)(h.user_data)
				st.matched    = "bare"
				st.target_len = copy(st.target_buf[:], http.route_target(ctx))
				st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
			},
		})
		http.route_get(&r, "/static/*", http.Handler{
			user_data = &cap,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Capture)(h.user_data)
				st.matched    = "wild"
				st.target_len = copy(st.target_buf[:], http.route_target(ctx))
				st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
			},
		})

		dispatch(t, &r, "/static", &cap)
		testing.expect_value(t, cap.matched, "bare")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/static")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "")

		dispatch(t, &r, "/static/", &cap)
		testing.expect_value(t, cap.matched, "wild")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/static/")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/")

		dispatch(t, &r, "/static/a", &cap)
		testing.expect_value(t, cap.matched, "wild")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/static/a")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/a")

		dispatch(t, &r, "/static/a/b/c?x=1", &cap)
		testing.expect_value(t, cap.matched, "wild")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/static/a/b/c")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/a/b/c")

		dispatch(t, &r, "/static/hello%20world.txt", &cap)
		testing.expect_value(t, cap.matched, "wild")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/static/hello world.txt")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/hello world.txt")
	}

	// 2. Root wildcard (/*) without explicit "/" vs with explicit "/".
	{
		cap: Capture
		r: http.Router
		defer http.router_destroy(r)

		http.route_get(&r, "/*", http.Handler{
			user_data = &cap,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Capture)(h.user_data)
				st.matched    = "root-wild"
				st.target_len = copy(st.target_buf[:], http.route_target(ctx))
				st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
			},
		})

		dispatch(t, &r, "/", &cap)
		testing.expect_value(t, cap.matched, "root-wild")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/")

		dispatch(t, &r, "/file.txt", &cap)
		testing.expect_value(t, cap.matched, "root-wild")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/file.txt")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/file.txt")

		http.route_get(&r, "/", http.Handler{
			user_data = &cap,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Capture)(h.user_data)
				st.matched    = "root-exact"
				st.target_len = copy(st.target_buf[:], http.route_target(ctx))
				st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
			},
		})

		dispatch(t, &r, "/", &cap)
		testing.expect_value(t, cap.matched, "root-exact")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "")
	}

	// 3. Bare wildcard (*).
	{
		cap: Capture
		r: http.Router
		defer http.router_destroy(r)

		http.route_get(&r, "*", http.Handler{
			user_data = &cap,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Capture)(h.user_data)
				st.matched    = "star"
				st.target_len = copy(st.target_buf[:], http.route_target(ctx))
				st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
			},
		})

		dispatch(t, &r, "/", &cap)
		testing.expect_value(t, cap.matched, "star")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/")

		dispatch(t, &r, "/foo/bar", &cap)
		testing.expect_value(t, cap.matched, "star")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/foo/bar")
	}

	// 4. Nested sub-router mounted at /api/*.
	{
		cap: Capture
		api: http.Router
		defer http.router_destroy(api)

		http.route_get(&api, "/users/:id", http.Handler{
			user_data = &cap,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Capture)(h.user_data)
				st.matched    = "api-user"
				st.target_len = copy(st.target_buf[:], http.route_target(ctx))
				st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
				st.id_len     = copy(st.id_buf[:],     http.route_param(http.route_params(ctx), "id"))
			},
		})
		http.route_get(&api, "/files/*", http.Handler{
			user_data = &cap,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Capture)(h.user_data)
				st.matched    = "api-files"
				st.target_len = copy(st.target_buf[:], http.route_target(ctx))
				st.suffix_len = copy(st.suffix_buf[:], http.route_suffix(ctx))
			},
		})

		root: http.Router
		defer http.router_destroy(root)
		http.route_all(&root, "/api/*", http.router(&api))

		dispatch(t, &root, "/api/users/42", &cap)
		testing.expect_value(t, cap.matched, "api-user")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/api/users/42")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "")
		testing.expect_value(t, string(cap.id_buf[:cap.id_len]), "42")

		dispatch(t, &root, "/api/files/dir/a.txt", &cap)
		testing.expect_value(t, cap.matched, "api-files")
		testing.expect_value(t, string(cap.target_buf[:cap.target_len]), "/api/files/dir/a.txt")
		testing.expect_value(t, string(cap.suffix_buf[:cap.suffix_len]), "/dir/a.txt")
	}
}
