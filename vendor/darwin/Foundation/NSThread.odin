//+build darwin
package objc_Foundation

@(objc_class="NSThread")
Thread :: struct {using _: Object}

@(objc_type=Thread, objc_name="alloc", objc_is_class_method=true)
Thread_alloc :: proc "c" () -> ^Thread {
	return msgSend(^Thread, Thread, "alloc")
}

@(objc_type=Thread, objc_name="initWithTarget", objc_is_class_method=true)
Thread_initWithTarget :: proc "c" (self: ^Thread, target: id, sel: SEL, object: id) -> ^Thread {
	return msgSend(^Thread, self, "initWithTarget:selector:object:", target, sel, object)
}

@(objc_type=Thread, objc_name="start", objc_is_class_method=true)
Thread_start :: proc "c" (self: ^Thread) {
	msgSend(^Thread, self, "start")
}
