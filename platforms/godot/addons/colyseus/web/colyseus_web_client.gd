class_name ColyseusWebClient
extends RefCounted
## Colyseus Web Client - JavaScript SDK Bridge
##
## This implementation uses JavaScriptBridge to communicate with the
## Colyseus JavaScript SDK for web exports.
##
## IMPORTANT: For web export to work, you must:
## 1. Use the custom HTML template: addons/colyseus/web/colyseus.html
## 2. Copy colyseus.js and colyseus_bridge.js to your export directory

var _js_client_id: int = -1
var _endpoint: String = ""
var _colyseus_godot: JavaScriptObject

## Create a new web client
func _init():
	# Get reference to the ColyseusGodot bridge object
	_colyseus_godot = JavaScriptBridge.get_interface("ColyseusGodot")
	if not _colyseus_godot:
		push_error("ColyseusWebClient: JavaScript bridge not available!")
		push_error("Make sure to:")
		push_error("  1. Use custom HTML template: res://addons/colyseus/web/colyseus.html")
		push_error("  2. Copy colyseus.js and colyseus_bridge.js to export directory")

## Set the server endpoint
func set_endpoint(endpoint: String) -> void:
	_endpoint = endpoint
	if not _colyseus_godot:
		return
	
	if _js_client_id < 0:
		var result = _colyseus_godot.createClient(endpoint)
		if result != null:
			_js_client_id = int(result)
		else:
			push_error("ColyseusWebClient: Failed to create client")

## Alternative name for set_endpoint (for compatibility)
func connect_to(endpoint: String) -> void:
	set_endpoint(endpoint)

## Get the server endpoint
func get_endpoint() -> String:
	return _endpoint

## Join or create a room
func join_or_create(room_name: String, options: Dictionary = {}) -> Variant:
	if not _ensure_connected():
		return null
	var web_room_script = load("res://addons/colyseus/web/colyseus_web_room.gd")
	var room = web_room_script.new()
	room._connect_join_or_create(_js_client_id, room_name, options)
	return room

## Create a new room
func create_room(room_name: String, options: Dictionary = {}) -> Variant:
	if not _ensure_connected():
		return null
	var web_room_script = load("res://addons/colyseus/web/colyseus_web_room.gd")
	var room = web_room_script.new()
	room._connect_create(_js_client_id, room_name, options)
	return room

## Join an existing room by name
func join(room_name: String, options: Dictionary = {}) -> Variant:
	if not _ensure_connected():
		return null
	var web_room_script = load("res://addons/colyseus/web/colyseus_web_room.gd")
	var room = web_room_script.new()
	room._connect_join(_js_client_id, room_name, options)
	return room

## Join a room by its ID
func join_by_id(room_id: String, options: Dictionary = {}) -> Variant:
	if not _ensure_connected():
		return null
	var web_room_script = load("res://addons/colyseus/web/colyseus_web_room.gd")
	var room = web_room_script.new()
	room._connect_join_by_id(_js_client_id, room_id, options)
	return room

## Reconnect to a room using reconnection token
func reconnect(reconnection_token: String) -> Variant:
	if not _ensure_connected():
		return null
	var web_room_script = load("res://addons/colyseus/web/colyseus_web_room.gd")
	var room = web_room_script.new()
	room._connect_reconnect(_js_client_id, reconnection_token)
	return room

## Ensure client is connected
func _ensure_connected() -> bool:
	if not _colyseus_godot:
		push_error("ColyseusWebClient: JavaScript bridge not available")
		return false
	if _js_client_id < 0:
		push_error("ColyseusWebClient: Must call set_endpoint() before joining rooms")
		return false
	return true

## Clean up
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _js_client_id >= 0 and _colyseus_godot:
			_colyseus_godot.disposeClient(_js_client_id)
