package tests_http

import "core:http"
import "core:testing"

@(test)
test_route_match :: proc(t: ^testing.T) {
	Case :: struct {
		pattern, path: string,
		vars: []http.Route_Param,
		suffix: string,
	}
	cases := [?]Case{
		{"/",               "/",                {},                             ""},
		{"/hello",          "/hello",           {},                             ""},
		{"/:",              "/hello",           {{"", "hello"}},                ""},
		{"/:/:",            "/hello/world",     {{"", "hello"}, {"", "world"}}, ""},
		{"/hello/*",        "/hello/world",     {},                             "/world"},
		{"/hello/:",        "/hello/world",     {{"", "world"}},                ""},
		{"/hello/:/*",      "/hello/world/foo", {{"", "world"}},                "/foo"},
		{"/api/*",          "/api/status",      {},                             "/status"},
		{"/api/:version/*", "/api/v2/status",   {{"version", "v2"}},            "/status"},
	}

	vars: [dynamic]http.Route_Param

	// It should leave existing vars alone.
	append(&vars, http.Route_Param{"test", "testvalue"})

	defer delete(vars)
	for tc, i in cases {
		resize(&vars, 1)
		suffix: string

		rt: http._Route_Trie
		defer http._route_trie_destroy(rt)
		http._route_trie_add(&rt, http.Route{
			handler = http.handler(http.handler_404),
			pattern = tc.pattern,
		})
		_, has_route := http._route_trie_match(rt, tc.path, &vars, &suffix)
		testing.expectf(t, has_route, "%v: %q does not match route %q", i, tc.pattern, tc.path)
		testing.expectf(t, suffix == tc.suffix, "%v: expected suffix %q but got %q", i, tc.suffix, suffix)
		testing.expectf(t, len(vars)-1 == len(tc.vars), "%v: %v != %v", i, vars, tc.vars)
		for ev, j in tc.vars {
			testing.expectf(t, vars[j+1] == ev, "%v: %v != %v", i, vars[j+1], ev)
		}
	}
}

@(test)
test_verify_routes :: proc(t: ^testing.T) {
	Case :: struct {
		a, b: string,
		ok: bool,
	}

	cases := [?]Case{
		// Identical static routes are a collision.
		{"/a/b",          "/a/b",              false}, 
		// Identical structure, different variable names. 
		// Matches the same input "/a/foo", so it's a collision.
		{"/a/:param",     "/a/:param2",        false}, 
		// Exact match is more specific than a parameter.
		{"/a/b",          "/a/:param",         true},  
		// Deep exact match is more specific than deep parameter.
		{"/a/b/c",        "/a/b/:param",       true},
		// Mixed: "a" vs "param" (1st specific) matches subset of "param" vs "param".
		{"/a/:param",     "/:param/:param2",   true}, 
		// Both match "/a/b". 
		// A has 1 static (pos 0). B has 1 static (pos 1). 
		// Neither is "more specific" than the other globally.
		{"/a/:param",     "/:param/b",         false}, 
		// Both match "/a/b/c".
		// A has 2 statics (pos 0, 2). B has 2 statics (pos 1, 2).
		// Equal specificity score = Conflict.
		{"/a/:param/c",   "/:param/b/c",       false}, 
		// Even though structure is similar, static segments mismatch.
		// A expects "b" at pos 1, B expects "c" at pos 1.
		{"/a/b/:param",   "/a/c/:param",       true}, 
		// Root mismatch.
		{"/a/:param",     "/b/:param",         true},
		// If your router doesn't ignore trailing slashes or support optional params,
		// different lengths usually don't conflict.
		{"/a/b",          "/a/b/c",            true},
		{"/:param",       "/:param/:param2",   true},
		// Input: "/a/b/c"
		// A: /a/param:/c (2 static segments)
		// B: /param:/b/param: (1 static segment)
		// A is strictly more specific than B.
		{"/a/:param/c",   "/:param/b/:param",  true},
		{"/a/b/c",        "/a/:param/:param2", true},
		{"/:param",       "/users/:id",        true},
		{"/a/b",          "/a/:param",         true},
		{"/:param/b",     "/a/:param",         false},
		{"/a/b",          "/a/b/c",            true},
		{"/v1/:id/name",  "/v1/:id/type",      true},
		{"/apple/:param", "/banana/:param",    true},
		{"/a/:year/11",   "/a/year/:month",    false},
	}

	for tc, i in cases {
		tt: http._Route_Trie
		defer http._route_trie_destroy(tt)
		http._route_trie_add(&tt, http.Route{pattern=tc.a, handler=http.handler(http.handler_404)})
		_, ok := http._route_trie_check_conflicts(tt, tc.b).?
		ok = !ok
		testing.expectf(t, ok == tc.ok, "%v: expected ok (duplicate) to be %v but got %v for routes %q and %q", i, tc.ok, ok, tc.a, tc.b)
	}
}
