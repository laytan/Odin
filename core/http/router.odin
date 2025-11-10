#+build !js
package http

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:strings"
import "core:text/regex"

Router :: struct {
	// Compiled patterns go here.
	pattern_allocator: runtime.Allocator,
	// Route lists go here.
	list_allocator:    runtime.Allocator,
	// Temporary allocations while setting up the routes go here.
	temp_allocator:    runtime.Allocator,

	routes: [Method][dynamic]Route,
	all:    [dynamic]Route,
}

@(private)
Route :: struct {
	regex:   regex.Regular_Expression,
	handler: Handler,
}

router_init :: proc(router: ^Router, pattern_allocator := context.allocator, list_allocator := context.allocator, temp_allocator := context.temp_allocator) {
	router.pattern_allocator = pattern_allocator
	router.list_allocator = list_allocator
	router.temp_allocator = temp_allocator

	router.all.allocator = list_allocator
	for &routes in router.routes {
		routes.allocator = list_allocator
	}
}

router :: proc(router: ^Router) -> Handler {
	h: Handler
	h.user_data = router

	h.handle = proc(handler: ^Handler, using ctx: ^Context) {
		router := (^Router)(handler.user_data)
		rline := req.line.(Requestline)

		if routes_try(router.routes[rline.method][:], ctx) {
			return
		}

		if routes_try(router.all[:], ctx) {
			return
		}

		log.infof("no route matched %s %s", method_string(rline.method), req.url.path)
		respond(res, Status.Not_Found)
	}

	return h
}

Route_Casing :: enum {
	Case_Insensitive,
	Case_Sensitive,
}


route_get_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.routes[.Get], pattern, handler, casing, loc)
}

route_get_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_get_handler(router, pattern, handler(p), casing, loc)
}

route_get :: proc {
	route_get_handler,
	route_get_proc,
}


route_post_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.routes[.Post], pattern, handler, casing, loc)
}

route_post_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_post_handler(router, pattern, handler(p), casing, loc)
}

route_post :: proc {
	route_post_handler,
	route_post_proc,
}


route_delete_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.routes[.Delete], pattern, handler, casing, loc)
}

route_delete_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_delete_handler(router, pattern, handler(p), casing, loc)
}

route_delete :: proc {
	route_delete_handler,
	route_delete_proc,
}


route_patch_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.routes[.Patch], pattern, handler, casing, loc)
}

route_patch_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_patch_handler(router, pattern, handler(p), casing, loc)
}

route_patch :: proc {
	route_patch_handler,
	route_patch_proc,
}


route_put_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.routes[.Put], pattern, handler, casing, loc)
}

route_put_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_put_handler(router, pattern, handler(p), casing, loc)
}

route_put :: proc {
	route_put_handler,
	route_put_proc,
}


route_head_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.routes[.Head], pattern, handler, casing, loc)
}

route_head_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_head_handler(router, pattern, handler(p), casing, loc)
}

route_head :: proc {
	route_head_handler,
	route_head_proc,
}


route_connect_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.routes[.Connect], pattern, handler, casing, loc)
}

route_connect_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_connect_handler(router, pattern, handler(p), casing, loc)
}

route_connect :: proc {
	route_connect_handler,
	route_connect_proc,
}


route_options_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.routes[.Options], pattern, handler, casing, loc)
}

route_options_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_options_handler(router, pattern, handler(p), casing, loc)
}

route_options :: proc {
	route_options_handler,
	route_options_proc,
}


route_trace_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.routes[.Trace], pattern, handler, casing, loc)
}

route_trace_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_trace_handler(router, pattern, handler(p), casing, loc)
}

route_trace :: proc {
	route_trace_handler,
	route_trace_proc,
}


route_all_handler :: proc(router: ^Router, pattern: string, handler: Handler, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_add(router, &router.all, pattern, handler, casing, loc)
}

route_all_proc :: proc(router: ^Router, pattern: string, p: Handle_Proc, casing: Route_Casing = .Case_Insensitive, loc := #caller_location) {
	route_all_handler(router, pattern, handler(p), casing, loc)
}

route_all :: proc {
	route_all_handler,
	route_all_proc,
}


@(private)
route_add :: proc(router: ^Router, routes: ^[dynamic]Route, pattern: string, handler: Handler, casing: Route_Casing, loc := #caller_location) {
	assert(len(pattern) > 0 && pattern[0] == '/', "route pattern must start with a /", loc)

	if router.pattern_allocator.procedure == nil {
		router_init(router)
	}

	anchored := strings.concatenate({"^", pattern, "$"}, router.temp_allocator)
	flags := regex.Flags{} if casing == .Case_Sensitive else regex.Flags{.Case_Insensitive}
	regex, err := regex.create(anchored, flags, router.pattern_allocator, router.temp_allocator)
	if err != nil {
		fmt.panicf("invalid route pattern: %v", err, loc=loc)
	}

	_ = append(routes, Route{regex, handler}) or_else panic("could not append route", loc=loc)
}

@(private)
routes_try :: proc(routes: []Route, using ctx: ^Context) -> bool {
	for route in routes {
		capture, matched := regex.match(route.regex, req.url.path, context.temp_allocator, context.temp_allocator)
		if matched {
			req.url_params = capture.groups[1:]
			rh := route.handler
			rh.handle(&rh, ctx)
			return true
		}
	}

	return false
}
