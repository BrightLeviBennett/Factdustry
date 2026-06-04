@tool
extends EditorPlugin

# ============================================================
# Manifest Builder — keeps data/game/manifest.json in sync with
# the .tres files on disk, automatically, from inside the editor.
# ============================================================
# The runtime Registry reads data/game/manifest.json to enumerate
# every .tres file, which sidesteps unreliable DirAccess listings
# inside exported PCKs (macOS especially). This plugin rebuilds
# that manifest so you never have to run tools/build_manifest.py
# by hand.
#
# It hooks TWO editor signals so every kind of change is caught:
#   - resource_saved     → fires when a .tres is created / edited / saved.
#   - filesystem_changed → fires after the editor rescans, catching
#                          DELETES and RENAMES (which never fire
#                          resource_saved) and external file adds.
#
# The build runs natively in GDScript rather than shelling out to
# python3 (the previous implementation): OS.execute("python3", …)
# silently fails when Godot is launched from Finder on macOS, since
# GUI apps don't inherit the shell PATH — which is why the manifest
# appeared to never update. The output is byte-identical to
# tools/build_manifest.py (both sort keys), so the two stay in sync.

const MANIFEST_PATH := "res://data/game/manifest.json"

# group key -> directory (res:// path, no trailing slash). MUST stay in sync
# with tools/build_manifest.py's GROUPS.
const GROUPS := {
	"items":          "res://data/game/tarkon/items",
	"blocks":         "res://data/game/tarkon/blocks",
	"units":          "res://data/game/tarkon/units",
	"fluids":         "res://data/game/tarkon/fluids",
	"tiles":          "res://data/game/tarkon/tiles",
	"status_effects": "res://data/game/tarkon/status_effects",
	"sectors":        "res://data/game/tarkon/sectors",
	"planets":        "res://data/game/planets",
	"archives":       "res://data/game/tarkon/archives",
}

## Debounce a burst of saves / filesystem events into a single rebuild.
var _pending_run := false
var _efs: EditorFileSystem


func _enter_tree() -> void:
	resource_saved.connect(_on_resource_saved)
	_efs = get_editor_interface().get_resource_filesystem()
	if _efs:
		_efs.filesystem_changed.connect(_on_filesystem_changed)


func _exit_tree() -> void:
	if resource_saved.is_connected(_on_resource_saved):
		resource_saved.disconnect(_on_resource_saved)
	if _efs and _efs.filesystem_changed.is_connected(_on_filesystem_changed):
		_efs.filesystem_changed.disconnect(_on_filesystem_changed)


func _on_resource_saved(resource: Resource) -> void:
	if resource == null:
		return
	var path: String = resource.resource_path
	if not path.ends_with(".tres"):
		return
	for dir in GROUPS.values():
		if path.begins_with(dir + "/"):
			_schedule_rebuild()
			return


func _on_filesystem_changed() -> void:
	# Catches deletes / renames / external adds that never fire resource_saved.
	# The rebuild is a no-op when the .tres set hasn't actually changed, so
	# firing on every rescan (and on our own write below) is harmless.
	_schedule_rebuild()


func _schedule_rebuild() -> void:
	if _pending_run:
		return
	_pending_run = true
	# Defer a short moment so a "save all" / multi-file op triggers one rebuild.
	var t := get_tree().create_timer(0.2)
	t.timeout.connect(_run_builder)


func _run_builder() -> void:
	_pending_run = false
	var built: Dictionary = _scan_groups()
	# Only write when the .tres set actually changed — compare against the
	# current file's CONTENT (not its bytes), so formatting never causes a
	# rewrite and our own write doesn't loop via filesystem_changed.
	if _matches_existing(built):
		return
	if _write_manifest(built):
		var total := 0
		for k in built:
			total += (built[k] as Array).size()
		print("[ManifestBuilder] manifest.json updated — %d entries across %d groups" % [total, built.size()])


## Scans every group directory and returns {group_key: [sorted res:// paths]}.
func _scan_groups() -> Dictionary:
	var out := {}
	for key in GROUPS:
		var dir_path: String = GROUPS[key]
		var files: Array = []
		var d := DirAccess.open(dir_path)
		if d == null:
			push_warning("[ManifestBuilder] directory missing: %s" % dir_path)
			out[key] = files
			continue
		d.list_dir_begin()
		var fn := d.get_next()
		while fn != "":
			if not d.current_is_dir() and fn.ends_with(".tres"):
				files.append(dir_path + "/" + fn)
			fn = d.get_next()
		d.list_dir_end()
		files.sort()
		out[key] = files
	return out


## True when the on-disk manifest already describes exactly `built`.
func _matches_existing(built: Dictionary) -> bool:
	if not FileAccess.file_exists(MANIFEST_PATH):
		return false
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	if parsed.size() != built.size():
		return false
	for key in built:
		if not parsed.has(key):
			return false
		var a: Array = built[key]
		var b: Array = parsed[key]
		if a.size() != b.size():
			return false
		for i in a.size():
			if String(a[i]) != String(b[i]):
				return false
	return true


## Writes the manifest. Returns true on success. JSON.stringify sorts keys,
## matching tools/build_manifest.py (sort_keys=True) byte-for-byte.
func _write_manifest(built: Dictionary) -> bool:
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[ManifestBuilder] could not open %s for writing" % MANIFEST_PATH)
		return false
	f.store_string(JSON.stringify(built, "  ") + "\n")
	f.close()
	return true
