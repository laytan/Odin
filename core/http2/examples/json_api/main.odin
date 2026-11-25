// REST API showcasing routing, sub-routers, middleware, cookies, forms, query filters, and JSON.
//
// Run: odin run core/http2/examples/json_api
//
// Try:
//   curl -i -c cookies.txt -d "user=alice" http://127.0.0.1:8080/login
//   curl -i -b cookies.txt -d '{"title":"hello","body":"world"}' http://127.0.0.1:8080/api/notes
//   curl -i -b cookies.txt "http://127.0.0.1:8080/api/notes?q=hello"
//   curl -i -b cookies.txt http://127.0.0.1:8080/api/notes/1
//   curl -i -b cookies.txt -X DELETE http://127.0.0.1:8080/api/notes/1
package main

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"

import http "core:http2"

Note :: struct {
	id:     int,
	author: string,
	title:  string,
	body:   string,
}

Store :: struct {
	// Handlers run concurrently across server worker threads, so shared state must be synchronized.
	mu:      sync.RW_Mutex,
	next_id: int,
	notes:   map[int]Note,
}

store: Store

Auth_User :: struct {
	name: string,
}

main :: proc() {
	api := http.make_router()
	http.route_get   (&api, "/notes",     list_notes)
	http.route_post  (&api, "/notes",     http.body_parser, create_note)
	http.route_get   (&api, "/notes/:id", get_note)
	http.route_delete(&api, "/notes/:id", delete_note)

	r := http.make_router()
	http.route_post(&r, "/login", http.body_parser, login)
	http.route_all (&r, "/api/*", require_auth, http.router(&api))

	fmt.println("Listening on http://127.0.0.1:8080")
	s := http.make_server(http.Server_Options{
		handlers = {http.logged, http.router(&r)},
	})
	err := http.listen_and_serve(&s)
	fmt.assertf(err == nil, "server error: %v", err)
}

require_auth :: proc(ctx: ^http.Ctx, next: []http.Handler) {
	user, ok := http.request_cookie_get(&ctx.req, "session")
	if !ok || user == "" {
		ctx.res.status = .Unauthorized
		http.respond_plain(&ctx.res, "unauthorized\n")
		return
	}
	http.context_add(ctx, Auth_User{name = user})
	http.handle(next, ctx)
}

login :: proc(ctx: ^http.Ctx) {
	body, body_ok := http.body_parser_collect(ctx)
	if !body_ok {
		ctx.res.status = .Bad_Request
		http.respond(&ctx.res)
		return
	}

	form, form_ok := http.body_url_encoded(string(body))
	user := form["user"]
	if !form_ok || user == "" {
		ctx.res.status = .Bad_Request
		http.respond_plain(&ctx.res, "missing user\n")
		return
	}

	http.set_cookie(&ctx.res, http.Cookie{
		name      = "session",
		value     = user,
		path      = "/",
		http_only = true,
		same_site = .Lax,
	})
	http.respond_plain(&ctx.res, fmt.tprintf("logged in as %s\n", user))
}

list_notes :: proc(ctx: ^http.Ctx) {
	query, has_query := http.query_get_percent_decoded(ctx.req.line.target, "q")

	matching := make([dynamic]Note)
	sync.shared_guard(&store.mu)
	for _, note in store.notes {
		if !has_query || strings.contains(note.title, query) || strings.contains(note.body, query) {
			append(&matching, note)
		}
	}

	slice.sort_by_key(matching[:], proc(n: Note) -> int { return n.id })
	http.respond_json(&ctx.res, matching[:])
}

create_note :: proc(ctx: ^http.Ctx) {
	Input :: struct {
		title: string,
		body:  string,
	}

	body, body_ok := http.body_parser_collect(ctx)
	if !body_ok {
		ctx.res.status = .Bad_Request
		http.respond(&ctx.res)
		return
	}

	input: Input
	if json.unmarshal(body, &input) != nil || input.title == "" {
		ctx.res.status = .Bad_Request
		http.respond_plain(&ctx.res, "invalid json\n")
		return
	}

	user := http.context_get(ctx, Auth_User)

	// Request and temp allocations are reclaimed when the response completes, so clone strings to retain.
	note := Note{
		id     = sync.atomic_add(&store.next_id, 1) + 1,
		author = strings.clone(user.name),
		title  = strings.clone(input.title),
		body   = strings.clone(input.body),
	}

	sync.guard(&store.mu)
	store.notes[note.id] = note

	ctx.res.status = .Created
	http.respond_json(&ctx.res, note)
}

get_note :: proc(ctx: ^http.Ctx) {
	id, ok := http.route_param_int(http.route_params(ctx), "id")
	if !ok {
		ctx.res.status = .Bad_Request
		http.respond_plain(&ctx.res, "invalid id\n")
		return
	}

	sync.shared_guard(&store.mu)
	note, found := store.notes[id]
	if !found {
		ctx.res.status = .Not_Found
		http.respond_plain(&ctx.res, "not found\n")
		return
	}
	http.respond_json(&ctx.res, note)
}

delete_note :: proc(ctx: ^http.Ctx) {
	id, ok := http.route_param_int(http.route_params(ctx), "id")
	if !ok {
		ctx.res.status = .Bad_Request
		http.respond_plain(&ctx.res, "invalid id\n")
		return
	}

	deleted := false
	if sync.guard(&store.mu) {
		if note, found := store.notes[id]; found {
			delete(note.author)
			delete(note.title)
			delete(note.body)
			delete_key(&store.notes, id)
			deleted = true
		}
	}

	if !deleted {
		ctx.res.status = .Not_Found
		http.respond_plain(&ctx.res, "not found\n")
		return
	}
	ctx.res.status = .No_Content
	http.respond(&ctx.res)
}
