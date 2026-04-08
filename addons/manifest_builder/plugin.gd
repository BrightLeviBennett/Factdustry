@tool
extends EditorPlugin

# ============================================================
# Manifest Builder — auto-runs tools/build_manifest.py whenever
# a .tres file under data/game/ is saved in the editor.
# ============================================================
# The runtime Registry reads data/game/manifest.json to enumerate
# every .tres file, which sidesteps unreliable DirAccess listings
# inside exported PCKs (macOS especially). This plugin keeps that
# manifest in sync automatically so you never have to remember to
# run the builder by hand.

const WATCHED_PREFIX := "res://data/game/"
const WATCHED_EXT := ".tres"
const BUILDER_SCRIPT := "res://tools/build_manifest.py"

## Debounce multiple saves in the same frame into a single run.
var _pending_run := false


func _enter_tree() -> void:
	resource_saved.connect(_on_resource_saved)


func _exit_tree() -> void:
	if resource_saved.is_connected(_on_resource_saved):
		resource_saved.disconnect(_on_resource_saved)


func _on_resource_saved(resource: Resource) -> void:
	if resource == null:
		return
	var path: String = resource.resource_path
	if not path.begins_with(WATCHED_PREFIX):
		return
	if not path.ends_with(WATCHED_EXT):
		return
	_schedule_rebuild()


func _schedule_rebuild() -> void:
	if _pending_run:
		return
	_pending_run = true
	# Defer by one frame so a single "save all" action only triggers once.
	call_deferred("_run_builder")


func _run_builder() -> void:
	_pending_run = false

	var project_root := ProjectSettings.globalize_path("res://")
	var script_abs := ProjectSettings.globalize_path(BUILDER_SCRIPT)

	if not FileAccess.file_exists(BUILDER_SCRIPT):
		push_warning("[ManifestBuilder] build_manifest.py not found at %s" % BUILDER_SCRIPT)
		return

	var output: Array = []
	var exit_code := OS.execute("python3", [script_abs], output, true)

	if exit_code == 0:
		print("[ManifestBuilder] manifest.json updated — ", "".join(output).strip_edges())
	else:
		push_warning("[ManifestBuilder] python3 tools/build_manifest.py failed (exit %d):\n%s" % [exit_code, "".join(output)])
