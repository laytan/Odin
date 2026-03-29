#+vet explicit-allocators
#+feature using-stmt
package http

Handler_Proc :: proc(handler: ^Handler, ctx: ^Ctx)
Handle_Proc  :: proc(ctx: ^Ctx)

Handler :: struct {
	user_data: rawptr,
	next:      Maybe(^Handler),
	handle:    Handler_Proc,
}

handler :: proc "contextless" (handle: Handle_Proc) -> Handler {
	h: Handler
	h.user_data = rawptr(handle)

	handle := proc(h: ^Handler, ctx: ^Ctx) {
		p := (Handle_Proc)(h.user_data)
		p(ctx)
	}

	h.handle = handle
	return h
}

handler_404 :: proc(using ctx: ^Ctx) {
	res.status = .Not_Found
	respond(&res)
}
