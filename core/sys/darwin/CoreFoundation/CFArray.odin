package CoreFoundation

foreign import CoreFoundation "system:CoreFoundation.framework"

ArrayRef :: distinct rawptr

@(link_prefix="CF")
foreign CoreFoundation {
	ArrayGetCount :: proc(theArray: ArrayRef) -> Index ---
	ArrayGetValueAtIndex :: proc(theArray: ArrayRef, idx: Index) -> rawptr ---
}
