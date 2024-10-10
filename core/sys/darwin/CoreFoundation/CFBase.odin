package CoreFoundation

foreign import CoreFoundation "system:CoreFoundation.framework"

TypeID      :: distinct uint
OptionFlags :: distinct uint
HashCode    :: distinct uint
Index       :: distinct int
TypeRef     :: distinct rawptr

Range :: struct {
	location: Index,
	length:   Index,
}

foreign CoreFoundation {
	// Releases a Core Foundation object.
	CFRelease :: proc(cf: TypeRef) ---
}

// Releases a Core Foundation object.
Release :: proc {
	ReleaseObject,
	ReleaseString,
	ReleaseDictionary,
}

ReleaseObject :: #force_inline proc(cf: TypeRef) {
	CFRelease(cf)
}
