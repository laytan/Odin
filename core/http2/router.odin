#+vet explicit-allocators
#+build !js
package http

import "base:runtime"
import "base:intrinsics"

import "core:net"
import "core:fmt"
import "core:io"
import "core:strings"

// Routes HTTP requests by method and URL path.
//
// Register routes with `route_get`, `route_post`, ..., `route_all` before starting the server,
// wrap `&r` with `router(&r)`, and free with `router_destroy(r)`. Both `r` and registered pattern
// strings must outlive the handler.
//
// **Patterns**:
// - Static segments match literally and are case-sensitive (e.g. `"/users/profile"`).
// - `:name` captures a single path segment (e.g. `"/users/:id"`), read via `route_params`,
//   `route_param`, or `route_param_int`.
// - `"*"` or a trailing `"/*"` matches any remaining path under that prefix (e.g. `"/static/*"`).
//   The matched remainder, starting with `'/'`, is returned by `route_suffix(ctx)`.
// - Query strings (`?a=1`) are ignored during matching and paths are percent-decoded first
//   (invalid escapes respond with `404 Not Found`).
//
// **Precedence & Conflicts**:
// - Method order: exact method -> `HEAD` falls back to `GET` (keeping method `.Head` so no body is
//   sent) -> `route_all` -> `404 Not Found`.
// - Pattern order: static > `:param` > wildcard.
// - Trailing slashes are equivalent on exact routes (`"/users"` and `"/users/"`), unless a prefix
//   wildcard is also registered (`"/static"` matches `"/static"`, `"/static/"` matches `"/static/*"`
//   with suffix `"/"`). Explicit `"/"` takes precedence over `"/*"` and `"*"`.
// - Ambiguous or duplicate routes panic at registration time.
//
// **Sub-Routers**:
// Mount another `router(&sub)` on a wildcard prefix (e.g. `route_all(&r, "/api/*", router(&api))`).
// The sub-router matches against the matched suffix while `route_target(ctx)` retains the full
// decoded path and `route_params(ctx)` accumulates outer and inner parameters.
//
// Example:
// 	api: http.Router
// 	defer http.router_destroy(api)
// 	http.route_get(&api, "/users/:id", proc(ctx: ^http.Ctx) {
// 		id, ok := http.route_param_int(http.route_params(ctx), "id")
// 		if !ok { ctx.res.status = .Bad_Request; http.respond(&ctx.res); return }
// 		_ = id
// 		http.respond_plain(&ctx.res, "user")
// 	})
//
// 	r: http.Router
// 	defer http.router_destroy(r)
// 	http.route_get(&r, "/", proc(ctx: ^http.Ctx) { http.respond_plain(&ctx.res, "home") })
// 	http.route_get(&r, "/static/*", proc(ctx: ^http.Ctx) {
// 		http.respond_dir(&ctx.res, "public", http.route_suffix(ctx))
// 	})
// 	http.route_all(&r, "/api/*", http.router(&api))
Router :: struct {
	routes: [Method]_Route_Trie,
	all:    _Route_Trie,
}

/* A registered route pairing a `Handler` with its pattern. */
Route :: struct {
	handler: Handler,
	pattern: string,
}

/* A captured `:name` path parameter (`name` omits the leading `':'`). */
Route_Param :: struct {
	name:  string,
	value: string,
}

/* Wraps `router` in a `Handler`. `router` must outlive the returned `Handler`. */
router :: proc(router: ^Router) -> Handler {
	h: Handler
	h.user_data = router

	h.handle = proc(h: ^Handler, ctx: ^Ctx) {
		router := (^Router)(h.user_data)
		rline := ctx.req.line

		match := context_get(ctx, _Route_Match)
		if match == nil {
			add_err: runtime.Allocator_Error
			match, add_err = context_add(ctx, _Route_Match{})
			if add_err != nil {
				invalid_request(connection_of_context(ctx), .Internal_Server_Error)
				return
			}
			match.vars.allocator = transaction_allocator(ctx)

			without_query, _, _ := strings.partition(rline.target, "?")
			target, target_ok := net.percent_decode(without_query, transaction_allocator(ctx))
			if !target_ok {
				ctx.res.status = .Not_Found
				respond(&ctx.res)
				return
			}
			match.target = target
		}

		target := match.target
		if match.suffix != "" {
			target = match.suffix
			match.suffix = ""
		}

		route, has_route := _route_trie_match(router.routes[rline.method], target, &match.vars, &match.suffix)
		if !has_route && rline.method == .Head {
			route, has_route = _route_trie_match(router.routes[.Get], target, &match.vars, &match.suffix)
		}
		if !has_route {
			route, has_route = _route_trie_match(router.all, target, &match.vars, &match.suffix)
			if !has_route {
				route = Route{handler(handler_404), ""}
			}
		}

		match.route = route
		route.handler.handle(&route.handler, ctx)
	}

	return h
}

/* Frees memory allocated by `r`. */
router_destroy :: proc(r: Router) {
	for trie in r.routes {
		_route_trie_destroy(trie)
	}
	_route_trie_destroy(r.all)
}

/* Writes a human-readable overview of registered routes to `w`. */
write_routes :: proc(w: io.Writer, r: Router) {
	for routes, method in r.routes {
		fmt.wprintln(w, method_string(method))
		for st in routes.segments {
			_route_trie_write(w, st)
		}
	}
	fmt.wprintln(w, "ALL")
	for st in r.all.segments {
		_route_trie_write(w, st)
	}
}

/*
Returns all captured `:param` values in path order.
Must be called from a handler dispatched by `router`.
*/
route_params :: proc(ctx: ^Ctx) -> (params: []Route_Param) {
	return context_get(ctx, _Route_Match).vars[:]
}

/*
Returns the full percent-decoded request path without the query string,
or `""` outside a `Router`.
*/
route_target :: proc(ctx: ^Ctx) -> string {
	match := context_get(ctx, _Route_Match)
	if match == nil { return "" }
	return match.target
}

/*
Returns the percent-decoded path remainder matched by a prefix wildcard (including its leading `'/'`,
e.g. `"/a/b"` or `"/"`), or `""` for non-wildcard routes or outside a `Router`.
*/
route_suffix :: proc(ctx: ^Ctx) -> string {
	match := context_get(ctx, _Route_Match)
	if match == nil { return "" }
	return match.suffix
}

/* Returns the value of the first parameter named `name`, or `""` if not found. */
route_param :: proc(params: []Route_Param, name: string) -> string {
	for param in params {
		if param.name == name { return param.value }
	}

	return ""
}

/*
Returns parameter `name` parsed as a non-negative base-10 integer,
or `(0, false)` if missing, invalid, or overflowing `int`.
*/
route_param_int :: proc(params: []Route_Param, name: string) -> (value: int, ok: bool) {
	val := route_param(params, name)
	if val == "" { return }

	as_int: int
	for ch in transmute([]byte)val {
		switch ch {
		case '0'..='9':
			overflow: bool
			if as_int, overflow = intrinsics.overflow_mul(as_int, 10);          overflow { return }
			if as_int, overflow = intrinsics.overflow_add(as_int, int(ch-'0')); overflow { return }
		case:
			return
		}
	}

	return as_int, true
}

route_get_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.routes[.Get], Route{handler, pattern}, loc)
}

route_get_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.routes[.Get], Route{handler(p), pattern}, loc)
}

/* Registers a `GET` route for `pattern`. */
route_get :: proc {
	route_get_handler,
	route_get_proc,
}


route_post_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.routes[.Post], Route{handler, pattern}, loc)
}

route_post_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.routes[.Post], Route{handler(p), pattern}, loc)
}

/* Registers a `POST` route for `pattern`. */
route_post :: proc {
	route_post_handler,
	route_post_proc,
}


route_delete_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.routes[.Delete], Route{handler, pattern}, loc)
}

route_delete_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.routes[.Delete], Route{handler(p), pattern}, loc)
}

/* Registers a `DELETE` route for `pattern`. */
route_delete :: proc {
	route_delete_handler,
	route_delete_proc,
}


route_patch_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.routes[.Patch], Route{handler, pattern}, loc)
}

route_patch_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.routes[.Patch], Route{handler(p), pattern}, loc)
}

/* Registers a `PATCH` route for `pattern`. */
route_patch :: proc {
	route_patch_handler,
	route_patch_proc,
}


route_put_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.routes[.Put], Route{handler, pattern}, loc)
}

route_put_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.routes[.Put], Route{handler(p), pattern}, loc)
}

/* Registers a `PUT` route for `pattern`. */
route_put :: proc {
	route_put_handler,
	route_put_proc,
}


route_head_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.routes[.Head], Route{handler, pattern}, loc)
}

route_head_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.routes[.Head], Route{handler(p), pattern}, loc)
}

/* Registers a `HEAD` route for `pattern`, overriding the `HEAD` -> `GET` fallback. */
route_head :: proc {
	route_head_handler,
	route_head_proc,
}


route_connect_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.routes[.Connect], Route{handler, pattern}, loc)
}

route_connect_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.routes[.Connect], Route{handler(p), pattern}, loc)
}

/* Registers a `CONNECT` route for `pattern`. */
route_connect :: proc {
	route_connect_handler,
	route_connect_proc,
}


route_options_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.routes[.Options], Route{handler, pattern}, loc)
}

route_options_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.routes[.Options], Route{handler(p), pattern}, loc)
}

/* Registers an `OPTIONS` route for `pattern`. */
route_options :: proc {
	route_options_handler,
	route_options_proc,
}


route_trace_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.routes[.Trace], Route{handler, pattern}, loc)
}

route_trace_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.routes[.Trace], Route{handler(p), pattern}, loc)
}

/* Registers a `TRACE` route for `pattern`. */
route_trace :: proc {
	route_trace_handler,
	route_trace_proc,
}


route_all_handler :: proc(r: ^Router, pattern: string, handler: Handler, loc := #caller_location) {
	_route_trie_add(&r.all, Route{handler, pattern}, loc)
}

route_all_proc :: proc(r: ^Router, pattern: string, p: Handle_Proc, loc := #caller_location) {
	_route_trie_add(&r.all, Route{handler(p), pattern}, loc)
}

/*
Registers a fallback route matching any HTTP method after method-specific routes.
Useful for catch-alls and mounting sub-routers.
*/
route_all :: proc {
	route_all_handler,
	route_all_proc,
}

_Route_Match :: struct {
	target: string,
	route:  Route,
	vars:   [dynamic]Route_Param,
	suffix: string,
}

_Route_Trie :: struct {
	segments: [dynamic]_Route_Trie,
	segment:  string,
	route:    Route,
}

_route_trie_destroy :: proc(t: _Route_Trie) {
	for st in t.segments {
		_route_trie_destroy(st)
	}
	delete(t.segments)
}

// Rejects overlapping prefix wildcards and equal-specificity (same depth & param count) collisions
// whose match result would otherwise depend on registration order.
_route_trie_check_conflicts :: proc(t: _Route_Trie, pattern: string, param_count := 0) -> Maybe(Route) {
	param_count, pattern := param_count, pattern

	is_prefix := pattern == "*" || strings.has_suffix(pattern, "/*")

	curr := t
	segments: for {
		segment, ok := _next_pattern_segment(&pattern)
		if !ok {
			if is_prefix {
				if len(curr.segments) > 0 {
					// "*" is always maintained as the last child segment.
					last := curr.segments[len(curr.segments)-1]
					if last.segment == "*" {
						return last.route
					}
				}
			} else {
				if curr.route.handler.handle != nil && pattern_param_count(curr.route.pattern) == param_count {
					return curr.route
				}
			}
			return nil
		}

		is_param := _is_param(segment)
		if is_param {
			param_count += 1
		}

		for &st in curr.segments {
			if is_param || _is_param(st.segment) {
				if conflict := _route_trie_check_conflicts(st, pattern, param_count); conflict != nil { return conflict }
			}
		}

		for &st in curr.segments {
			if st.segment == segment {
				if conflict := _route_trie_check_conflicts(st, pattern, param_count); conflict != nil { return conflict }
				curr = st
				continue segments
			}
		}

		return nil
	}

	pattern_param_count :: proc(pattern: string) -> (param_count: int) {
		pattern := pattern
		for segment in _next_pattern_segment(&pattern) {
			if _is_param(segment) {
				param_count += 1
			}
		}
		return
	}
}

// Inserts `route` into the trie while maintaining per-level child ordering:
// static segments first, `:param` segments next, and `*` last.
// Patterns beginning with `'/'` produce a leading `""` segment node mirroring path splitting.
_route_trie_add :: proc(t: ^_Route_Trie, route: Route, loc := #caller_location) {
	pattern := route.pattern
	assert(pattern != "", loc=loc)

	if conflict, has_conflict := _route_trie_check_conflicts(t^, pattern).?; has_conflict {
		fmt.panicf("route determinism conflict: %q and %q can both match the same path", route.pattern, conflict.pattern, loc=loc)
	}

	is_prefix := pattern == "*" || strings.has_suffix(pattern, "/*")

	curr := t
	segments: for {
		segment, ok := _next_pattern_segment(&pattern)
		if !ok {
			if is_prefix {
				prefix_segment := make_trie("*", curr.segments.allocator)
				prefix_segment.route = route
				append(&curr.segments, prefix_segment)
			} else {
				assert(curr.route.handler.handle == nil)
				curr.route = route
			}
			return
		}

		insertion_point := len(curr.segments)
		insertion_check: for &st, i in curr.segments {
			switch {
			case st.segment == segment:
				curr = &st
				continue segments
			case st.segment == "*" || _is_param(st.segment):
				insertion_point = i
				break insertion_check
			}
		}

		inject_at(&curr.segments, insertion_point, make_trie(segment, curr.segments.allocator))
		curr = &curr.segments[insertion_point]
	}

	make_trie :: proc(segment: string, allocator: runtime.Allocator) -> _Route_Trie {
		t: _Route_Trie
		t.segment = segment
		t.segments.allocator = allocator
		return t
	}
}

_route_trie_match :: proc(t: _Route_Trie, path: string, vars: ^[dynamic]Route_Param, suffix: ^string) -> (Route, bool) {
	assert(path[0] == '/')
	return _trie_match(t, path, vars, len(vars), suffix, at_root = true)

	_trie_match :: proc(t: _Route_Trie, path: string, vars: ^[dynamic]Route_Param, vars_start: int, suffix: ^string, at_root: bool) -> (Route, bool) {
		orig_path := path
		path := path
		segment, ok := _next_path_segment(&path)
		if !ok {
			// On "/", an explicit "/" route (registered on the leading `""` node) takes priority over "/*".
			if t.segment == "" && t.route.handler.handle != nil {
				return t.route, true
			}
			// When `!at_root`, `orig_path` is a non-empty or empty subslice immediately following the `'/'`
			// consumed into this node, so indexing `[-1]` inspects that preceding slash safely.
			// Route trailing-slash prefix roots (e.g. "/static/" on "/static/*", or "/" on "/*") to `*`.
			if !at_root && raw_data(orig_path)[-1] == '/' {
				for ts in t.segments {
					if ts.segment == "*" {
						assert(ts.route.handler.handle != nil)
						suffix^ = "/"
						return ts.route, true
					}
				}
			}
			return t.route, t.route.handler.handle != nil
		}

		// NOTE: could binary search but I don't think it's worth it for the amount of paths you usually have.

		for ts in t.segments {
			switch {
			case ts.segment == "*":
				assert(ts.route.handler.handle != nil)
				if at_root {
					suffix^ = orig_path
				} else {
					// Step back 1 byte to include the `'/'` consumed entering this parent node.
					suffix^ = string(raw_data(orig_path)[-1:][:len(orig_path)+1])
				}
				return ts.route, true

			case _is_param(ts.segment):
				if match, has_match := _trie_match(ts, path, vars, vars_start, suffix, at_root = false); has_match {
					// Inject at `vars_start` as recursion unwinds so params stay in outer-to-inner
					// path order without mutating `vars` on failed branches or shifting parent sub-router params.
					inject_at(vars, vars_start, Route_Param{
						name  = ts.segment[1:],
						value = segment,
					})
					return match, true
				}

			case ts.segment == segment:
				if match, has_match := _trie_match(ts, path, vars, vars_start, suffix, at_root = false); has_match {
					return match, true
				}
			}
		}

		return {}, false
	}
}

_route_trie_write :: proc(w: io.Writer, t: _Route_Trie, indent := 0) {
	for _ in 0..<indent { fmt.wprint(w, "\t") }
	pre := "/" if t.segment == "" else ""
	if t.route.handler.handle != nil {
		fmt.wprintfln(w, "%s%s -> %p", pre, t.segment, rawptr(t.route.handler.handle))
	} else {
		fmt.wprintfln(w, "%s%s", pre, t.segment)
	}
	for ts in t.segments {
		_route_trie_write(w, ts, indent+1)
	}
}

@(private="file")
_next_pattern_segment :: proc(s: ^string) -> (res: string, ok: bool) {
	st := s^

	if st == "*" {
		return st, false
	}

	m := strings.index_byte(st, '/')
	if m < 0 {
		res = st[:]
		ok  = len(res) > 0
		s^  = s[len(st):]
	} else {
		ok  = true
		res = s[:m]
		s^  = s[m+1:]
	}
	return
}

@(private="file")
_next_path_segment :: proc(s: ^string) -> (res: string, ok: bool) {
	m := strings.index_byte(s^, '/')
	if m < 0 {
		res = s[:]
		ok  = len(res) > 0
		s^  = s[len(s):]
	} else {
		ok  = true
		res = s[:m]
		s^  = s[m+1:]
	}
	return
}

@(private="file")
_is_param :: proc(segment: string) -> bool {
	return len(segment) > 0 && segment[0] == ':'
}
