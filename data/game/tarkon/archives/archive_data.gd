@tool
class_name ArchiveData
extends Resource

# ============================================================
# ARCHIVE_DATA.GD — Data definition for an Archive.
# Each .tres file using this script is one decodable archive that
# appears as a node in the tech tree. Archives only carry identity
# + presentation; the unlocks they gate live on other tech nodes
# (via the "-D-<archive_id>" dependency markers).
# ============================================================

## Unique ID used in code (e.g. "archive_better_turrets").
@export var id: StringName = &""
## Display name shown to the player (e.g. "Archive: Better Turrets").
@export var display_name: String = ""
## Icon texture shown in the tech tree / database (optional).
@export var icon: Texture2D
## Description shown in tooltips / the database (optional).
@export_multiline var description: String = ""
