@tool
extends EditorScript

# Bulk-flips `mipmaps/generate=false` → `true` in every `.import` file
# under `res://textures/`. Existing texture imports were generated when
# the project default had mipmaps OFF; this fixes them in-place so
# Linear-with-Mipmaps canvas filtering can actually sample from a mip
# pyramid (otherwise zoom-out still shimmers).
#
# To use: open this file in the script editor, then File → Run.
# After it finishes, in the editor's FileSystem dock select
# `res://textures/`, right-click → Reimport, and let Godot regenerate
# the .ctex files. Done once — afterwards the importer default keeps
# new imports correct.

const _ROOTS: Array[String] = ["res://textures"]


func _run() -> void:
	var changed: int = 0
	var scanned: int = 0
	for root in _ROOTS:
		var stack: Array[String] = [root]
		while not stack.is_empty():
			var dir_path: String = stack.pop_back()
			var dir = DirAccess.open(dir_path)
			if dir == null:
				continue
			dir.list_dir_begin()
			var name: String = dir.get_next()
			while name != "":
				if name in [".", ".."]:
					name = dir.get_next()
					continue
				var full: String = dir_path + "/" + name
				if dir.current_is_dir():
					stack.append(full)
				elif name.ends_with(".import"):
					scanned += 1
					if _patch_import(full):
						changed += 1
				name = dir.get_next()
			dir.list_dir_end()
	print("[mipmap-fix] scanned %d .import files, rewrote %d." % [scanned, changed])
	print("[mipmap-fix] now reimport `res://textures/` from the FileSystem dock.")


func _patch_import(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text: String = f.get_as_text()
	f.close()
	if not "mipmaps/generate=false" in text:
		return false
	var new_text: String = text.replace("mipmaps/generate=false", "mipmaps/generate=true")
	if new_text == text:
		return false
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		return false
	w.store_string(new_text)
	w.close()
	return true
