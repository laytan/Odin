package CoreFoundation

foreign import CoreFoundation "system:CoreFoundation.framework"

Dictionary :: distinct TypeRef

@(link_prefix="CF")
foreign CoreFoundation {
	DictionaryGetValueIfPresent :: proc(theDict: Dictionary, key: TypeRef, value: ^TypeRef) -> bool ---
	DictionaryGetValue :: proc(theDict: Dictionary, key: TypeRef) -> TypeRef ---

	@(link_name="_CFCopySupplementalVersionDictionary")
	_CopySupplementalVersionDictionary :: proc() -> Dictionary ---
	@(link_name="_kCFSystemVersionBuildVersionKey")
	_kSystemVersionBuildVersionKey: String
	@(link_name="_kCFSystemVersionProductNameKey")
	_kSystemVersionProductNameKey: String
	@(link_name="_kCFSystemVersionProductVersionExtraKey")
	_kSystemVersionProductVersionExtraKey: String
	@(link_name="_kCFSystemVersionProductVersionKey")
	_kSystemVersionProductVersionKey: String
}

ReleaseDictionary :: #force_inline proc(theDict: Dictionary) {
	CFRelease(TypeRef(theDict))
}
