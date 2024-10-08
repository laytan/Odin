package os2

import "base:runtime"

import "core:path/filepath"
import "core:strings"

Path_Separator        :: _Path_Separator        // OS-Specific
Path_Separator_String :: _Path_Separator_String // OS-Specific
Path_List_Separator   :: _Path_List_Separator   // OS-Specific

@(require_results)
is_path_separator :: proc(c: byte) -> bool {
	return _is_path_separator(c)
}

mkdir :: make_directory

make_directory :: proc(name: string, perm: int = 0o755) -> Error {
	return _mkdir(name, perm)
}

mkdir_all :: make_directory_all

make_directory_all :: proc(path: string, perm: int = 0o755) -> Error {
	return _mkdir_all(path, perm)
}

remove_all :: proc(path: string) -> Error {
	return _remove_all(path)
}

getwd :: get_working_directory

@(require_results)
get_working_directory :: proc(allocator: runtime.Allocator) -> (dir: string, err: Error) {
	return _get_working_directory(allocator)
}

setwd :: set_working_directory

set_working_directory :: proc(dir: string) -> (err: Error) {
	return _set_working_directory(dir)
}

lookup_executable :: proc(name: string, wd: string = "") -> (file: ^File, err: Error) {
	if strings.index_byte(name, Path_Separator) >= 0 {
		file, err = open(name)
		if err == nil && !is_executable(file) {
			close(file)
			err = .Permission_Denied
		}
		return
	}

	TEMP_ALLOCATOR_GUARD()

	path_b    := make([dynamic]byte, temp_allocator())
	paths_str := get_env("PATH", temp_allocator()) // TODO: is this correct on Windows?
	paths     := filepath.split_list(paths_str, temp_allocator())
	
	try :: proc(path_b: ^[dynamic]byte, dir, name: string) -> (file: ^File, err: Error) {
		clear(path_b)
		append(path_b, dir)
		append(path_b, Path_Separator)
		append(path_b, name)

		file, err = open(string(path_b[:]))
		if err == nil && !is_executable(file) {
			close(file)
			err = .Permission_Denied
		}
		return
	}

	for dir in paths {
		file = try(&path_b, dir, name) or_continue
		return
	}

	wd := wd
	if wd == "" {
		wd = getwd(temp_allocator()) or_return
	}
	return try(&path_b, wd, name)
}
