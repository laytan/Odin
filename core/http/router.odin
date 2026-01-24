#+build !js
package http

import "core:testing"
import "base:runtime"

import "core:fmt"
import "core:log"
import "core:strings"
import "core:bytes"
import "core:text/regex"







// "/"
// "/."
// "/."
// "/$arg/..."
// "/hello/world/"
// "/hello/world/{"
// "/hello/world/<>*/"



// "/" -> index_handler
// "/static/." -> static_handler
// "/api/." -> api_v1_handler
// "/api/v2/." -> api_v2_handler

ROUTE_404 := Route{handler(handle_404), ""}

handle_404 :: proc(ctx: ^Context) {
	respond_with_status(ctx.res, .Not_Found)
}

Route :: struct {
	handler: Handler,
	pattern: string,
}

Router :: struct {
	routes: [Method][dynamic]Route,
	all:    [dynamic]Route,
}

Route_Match :: struct {
	vars:   [dynamic]string,
	suffix: string,
}

router :: proc(router: ^Router) -> Handler {
	h: Handler
	h.user_data = router

	// TODO: sort routes based on specificity
	// TODO: panic if 2 routes are the same specificity
	// TODO: routes_match can then stop at first match

	h.handle = proc(handler: ^Handler, using ctx: ^Context) {
		router := (^Router)(handler.user_data)
		rline := req.line.(Requestline)

		// TODO: URL decoded
		target := rline.target.(string)

		match_ptr, has_match := ctx.vals[Route_Match]
		match := (^Route_Match)(match_ptr)
		if has_match {
			if match.suffix != "" {
				target = match.suffix
			}
		} else {
			match_ptr = new(Route_Match, context.temp_allocator)
			ctx.vals[Route_Match] = match_ptr
			match = (^Route_Match)(match_ptr)
		}

		// _, match_ptr, is_new, _ := map_entry(&ctx.vals, typeid_of(Route_Match))
		// if is_new {
		// 	match_ptr^ = new(Route_Match, context.temp_allocator)
		// }
		//
		// // ^rawptr
		// // ^^Route_Match
		//
		// match := (^^Route_Match)(match_ptr)^
		// if match.suffix != "" {
		// 	target = match.suffix
		// }
		fmt.println(has_match, match, target)

		route := routes_match(router.routes[rline.method][:], target, &match.vars, &match.suffix)
		if route == ROUTE_404 {
			route = routes_match(router.all[:], target, &match.vars, &match.suffix)
		}

		fmt.println(has_match, match, target)

		route.handler.handle(&route.handler, ctx)
	}

	return h
}

route_params :: proc(ctx: ^Context) -> (params: []string, suffix: string) {
	match := (^Route_Match)(ctx.vals[typeid_of(Route_Match)])
	fmt.println(match)
	return match.vars[:], match.suffix
}

Route_Score :: enum {
	None,
	Not_Found,
	Prefix,
	Var,
	Exact,
}

routes_match :: proc(routes: []Route, path: string, vars: ^[dynamic]string, suffix: ^string) -> Route {
	start_vars := len(vars)
	match := ROUTE_404
	score := Route_Score.Not_Found
	for route in routes {
		match_vars := len(vars)
		this_suffix: string
		this_score := route_match(route, path, .Case_Insensitive, vars, &this_suffix)
		if this_score == .Exact {
			suffix^ = this_suffix
			remove_range(vars, start_vars, match_vars)
			return route
		}

		if this_score > score {
			score = this_score
			match = route
			suffix^ = this_suffix
			remove_range(vars, start_vars, match_vars)
			continue
		}

		resize(vars, match_vars)
	}

	return match
}

route_match :: proc(route: Route, path: string, casing := Route_Casing.Case_Sensitive, vars: ^[dynamic]string, suffix: ^string) -> Route_Score {
	switch route.pattern {
	case "":
		return path == "/" ? .Exact : .None
	case "/":
		suffix^ = path
		return .Prefix
	}

	assert(path[0] == '/')
	path    := path[1:]
	pattern := route.pattern

	if len(pattern) > 0 && pattern[0] == '/' {
		pattern = pattern[1:]
	}

	is_prefix: bool
	if len(pattern) > 0 && pattern[len(pattern)-1] == '/' {
		pattern = pattern[:len(pattern)-1]
		is_prefix = true
	}

	max_score := Route_Score.Exact
	for {
		pattern_part, more_pattern := next_segment(&pattern)
		path_part,    more_path    := next_segment(&path)
		switch {
		case !more_pattern && !more_path:
			return is_prefix ? .None : max_score

		case !more_pattern && more_path:
			if is_prefix {
				suffix^ = string(raw_data(path)[-len(path_part)-1:][:len(path)+len(path_part)+1])
				return .Prefix
			}

			return .None

		case more_pattern && !more_path:
			return .None

		case len(pattern_part) == 1 && pattern_part[0] == '*':
			// TODO: named vars
			append(vars, path_part)
			max_score = .Var

		case casing == .Case_Insensitive && string(pattern_part) != string(path_part):
			return .None

		case casing == .Case_Sensitive && !strings.equal_fold(string(pattern_part), string(path_part)):
			return .None
		}
	}

	next_segment :: #force_inline proc(s: ^string) -> (res: string, ok: bool) {
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
}

@(test)
test_route_match :: proc(t: ^testing.T) {
	Case :: struct {
		pattern, path: string,
		score: Route_Score,
		casing: Route_Casing,
		vars: []string,
		suffix: string,
	}
	cases := [?]Case{
		{"", "/", .Exact, .Case_Insensitive, {}, ""},
		{"/", "/", .Prefix, .Case_Insensitive, {}, "/"},
		{"/hello", "/hello", .Exact, .Case_Insensitive, {}, ""},
		{"/*", "/hello", .Var, .Case_Insensitive, {"hello"}, ""},
		{"/*", "/", .None, .Case_Insensitive, {}, ""},
		{"/hello/", "/hello", .None, .Case_Insensitive, {}, ""},
		{"/hello/", "/hello/world", .Prefix, .Case_Insensitive, {}, "/world"},
		{"/hello/*", "/hello/world", .Var, .Case_Insensitive, {"world"}, ""},
		{"/hello/*/", "/hello/world/foo", .Prefix, .Case_Insensitive, {"world"}, "/foo"},
		{"/api/", "/api/status", .Prefix, .Case_Insensitive, {}, "/status"},
		{"/api/*/", "/api/v2/status", .Prefix, .Case_Insensitive, {"v2"}, "/status"},
	}
	vars: [dynamic]string
	for tc, i in cases {
		log.info(i)
		clear(&vars)
		suffix: string
		score := route_match({{}, tc.pattern}, tc.path, tc.casing, &vars, &suffix)
		testing.expectf(t, score == tc.score, "%v: %q, %q = %v (expected %v)", i, tc.pattern, tc.path, score, tc.score)
		testing.expect_value(t, suffix, tc.suffix)
		testing.expectf(t, len(vars) == len(tc.vars), "%v != %v", vars, tc.vars)
		for ev, i in tc.vars {
			testing.expect_value(t, vars[i], ev)
		}
	}
}











// Router :: struct {
// 	// Compiled patterns go here.
// 	pattern_allocator: runtime.Allocator,
// 	// Route lists go here.
// 	list_allocator:    runtime.Allocator,
// 	// Temporary allocations while setting up the routes go here.
// 	temp_allocator:    runtime.Allocator,
//
// 	routes: [Method][dynamic]Route,
// 	all:    [dynamic]Route,
// }
//
// @(private)
// Route :: struct {
// 	regex:   regex.Regular_Expression,
// 	handler: Handler,
// }
//
// router_init :: proc(router: ^Router, pattern_allocator := context.allocator, list_allocator := context.allocator, temp_allocator := context.temp_allocator) {
// 	router.pattern_allocator = pattern_allocator
// 	router.list_allocator = list_allocator
// 	router.temp_allocator = temp_allocator
//
// 	router.all.allocator = list_allocator
// 	for &routes in router.routes {
// 		routes.allocator = list_allocator
// 	}
// }
//
// router :: proc(router: ^Router) -> Handler {
// 	h: Handler
// 	h.user_data = router
//
// 	h.handle = proc(handler: ^Handler, using ctx: ^Context) {
// 		router := (^Router)(handler.user_data)
// 		rline := req.line.(Requestline)
//
// 		if routes_try(router.routes[rline.method][:], ctx) {
// 			return
// 		}
//
// 		if routes_try(router.all[:], ctx) {
// 			return
// 		}
//
// 		log.infof("no route matched %s %s", method_string(rline.method), req.url.path)
// 		respond(res, Status.Not_Found)
// 	}
//
// 	return h
// }
//
Route_Casing :: enum {
	Case_Insensitive,
	Case_Sensitive,
}
//
//
// route_get_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.routes[.Get], pattern, handler, casing, loc)
// }
//
// route_get_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_get_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_get :: proc {
// 	route_get_handler,
// 	route_get_proc,
// }
//
//
// route_post_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.routes[.Post], pattern, handler, casing, loc)
// }
//
// route_post_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_post_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_post :: proc {
// 	route_post_handler,
// 	route_post_proc,
// }
//
//
// route_delete_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.routes[.Delete], pattern, handler, casing, loc)
// }
//
// route_delete_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_delete_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_delete :: proc {
// 	route_delete_handler,
// 	route_delete_proc,
// }
//
//
// route_patch_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.routes[.Patch], pattern, handler, casing, loc)
// }
//
// route_patch_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_patch_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_patch :: proc {
// 	route_patch_handler,
// 	route_patch_proc,
// }
//
//
// route_put_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.routes[.Put], pattern, handler, casing, loc)
// }
//
// route_put_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_put_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_put :: proc {
// 	route_put_handler,
// 	route_put_proc,
// }
//
//
// route_head_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.routes[.Head], pattern, handler, casing, loc)
// }
//
// route_head_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_head_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_head :: proc {
// 	route_head_handler,
// 	route_head_proc,
// }
//
//
// route_connect_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.routes[.Connect], pattern, handler, casing, loc)
// }
//
// route_connect_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_connect_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_connect :: proc {
// 	route_connect_handler,
// 	route_connect_proc,
// }
//
//
// route_options_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.routes[.Options], pattern, handler, casing, loc)
// }
//
// route_options_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_options_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_options :: proc {
// 	route_options_handler,
// 	route_options_proc,
// }
//
//
// route_trace_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.routes[.Trace], pattern, handler, casing, loc)
// }
//
// route_trace_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_trace_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_trace :: proc {
// 	route_trace_handler,
// 	route_trace_proc,
// }
//
//
// route_all_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_add(router, &router.all, pattern, handler, casing, loc)
// }
//
// route_all_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
// 	route_all_handler(router, pattern, handler(p), casing, loc)
// }
//
// route_all :: proc {
// 	route_all_handler,
// 	route_all_proc,
// }
//
//
// @(private)
// route_add :: proc(router: ^Router, routes: ^[dynamic]Route, pattern: string, handler: Handler, casing: Route_Casing, loc := #caller_location) {
// 	assert(len(pattern) > 0 && pattern[0] == '/', "route pattern must start with a /", loc)
//
// 	if router.pattern_allocator.procedure == nil {
// 		router_init(router)
// 	}
//
// 	anchored := strings.concatenate({"^", pattern, "$"}, router.temp_allocator)
// 	flags := regex.Flags{} if casing == .Case_Sensitive else regex.Flags{.Case_Insensitive}
// 	regex, err := regex.create(anchored, flags, router.pattern_allocator, router.temp_allocator)
// 	if err != nil {
// 		fmt.panicf("invalid route pattern: %v", err, loc=loc)
// 	}
//
// 	_ = append(routes, Route{regex, handler}) or_else panic("could not append route", loc=loc)
// }
//
// @(private)
// routes_try :: proc(routes: []Route, using ctx: ^Context) -> bool {
// 	for route in routes {
// 		capture, matched := regex.match(route.regex, req.url.path, context.temp_allocator, context.temp_allocator)
// 		if matched {
// 			req.url_params = capture.groups[1:]
// 			rh := route.handler
// 			rh.handle(&rh, ctx)
// 			return true
// 		}
// 	}
//
// 	return false
// }
