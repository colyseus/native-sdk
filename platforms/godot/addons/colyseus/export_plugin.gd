@tool
extends EditorExportPlugin

const PLUGIN_PATH = "res://addons/colyseus/"
const WEB_PATH = PLUGIN_PATH + "web/"

var _js_files := [
	"colyseus.js",
	"colyseus_bridge.js",
]

func _get_name() -> String:
	return "Colyseus"

func _supports_platform(_platform: EditorExportPlatform) -> bool:
	return true

var _is_web_export := false
var _export_path := ""

func _export_begin(features: PackedStringArray, _is_debug: bool, path: String, _flags: int) -> void:
	_is_web_export = features.has("web")
	_export_path = path

func _export_end() -> void:
	if not _is_web_export:
		return
	
	if _export_path.is_empty():
		push_error("[Colyseus] Could not determine export path")
		return
	
	var export_dir := _export_path.get_base_dir()
	
	for js_file in _js_files:
		var source_path: String = WEB_PATH + js_file
		var dest_path: String = export_dir + "/" + js_file
		var err := DirAccess.copy_absolute(
			ProjectSettings.globalize_path(source_path),
			dest_path
		)
		if err == OK:
			print("[Colyseus] Copied %s to %s" % [js_file, dest_path])
		else:
			push_error("[Colyseus] Failed to copy %s to %s (error: %d)" % [js_file, dest_path, err])
