// =============================================================================
// Colyseus GML Wrapper — event constants, callback dispatch, helper functions
// =============================================================================

// Event type constants
#macro COLYSEUS_EVENT_NONE            0
#macro COLYSEUS_EVENT_ROOM_JOIN       1
#macro COLYSEUS_EVENT_STATE_CHANGE    2
#macro COLYSEUS_EVENT_ROOM_MESSAGE    3
#macro COLYSEUS_EVENT_ROOM_ERROR      4
#macro COLYSEUS_EVENT_ROOM_LEAVE      5
#macro COLYSEUS_EVENT_CLIENT_ERROR    6
#macro COLYSEUS_EVENT_PROPERTY_CHANGE 7
#macro COLYSEUS_EVENT_ITEM_ADD        8
#macro COLYSEUS_EVENT_ITEM_REMOVE     9
#macro COLYSEUS_EVENT_HTTP_RESPONSE   10
#macro COLYSEUS_EVENT_HTTP_ERROR      11

// Field type constants (matches colyseus_field_type_t)
#macro COLYSEUS_TYPE_STRING   0
#macro COLYSEUS_TYPE_NUMBER   1
#macro COLYSEUS_TYPE_BOOLEAN  2
#macro COLYSEUS_TYPE_INT8     3
#macro COLYSEUS_TYPE_UINT8    4
#macro COLYSEUS_TYPE_INT16    5
#macro COLYSEUS_TYPE_UINT16   6
#macro COLYSEUS_TYPE_INT32    7
#macro COLYSEUS_TYPE_UINT32   8
#macro COLYSEUS_TYPE_INT64    9
#macro COLYSEUS_TYPE_UINT64   10
#macro COLYSEUS_TYPE_FLOAT32  11
#macro COLYSEUS_TYPE_FLOAT64  12
#macro COLYSEUS_TYPE_REF      13
#macro COLYSEUS_TYPE_ARRAY    14
#macro COLYSEUS_TYPE_MAP      15

// Message payload type constants (matches colyseus_message_type_t)
#macro COLYSEUS_MSG_NIL    0
#macro COLYSEUS_MSG_BOOL   1
#macro COLYSEUS_MSG_INT    2
#macro COLYSEUS_MSG_UINT   3
#macro COLYSEUS_MSG_FLOAT  4
#macro COLYSEUS_MSG_STR    5
#macro COLYSEUS_MSG_BIN    6
#macro COLYSEUS_MSG_ARRAY  7
#macro COLYSEUS_MSG_MAP    8

// Internal globals for dispatch
global.__colyseus_room_handlers = ds_map_create();  // keyed by room_ref (real)
global.__colyseus_schema_handlers = array_create(256, undefined);
global.__colyseus_schema_meta = array_create(256, undefined);  // callback index → { parent_handle, field }
global.__colyseus_http_handlers = ds_map_create();  // keyed by request handle (real)
global.__colyseus_schema_structs = ds_map_create();  // keyed by instance handle (real) → GML struct
global.__colyseus_current_room_ref = -1;  // set during event processing / state access for room tagging

#macro __COLYSEUS_AUTH_FILE "colyseus_auth.dat"

// =============================================================================
// Client creation — wraps native + restores auth token
// =============================================================================

/// Create a Colyseus client. Automatically restores a previously saved auth token.
/// @param {String} _endpoint  Server endpoint (e.g., "http://localhost:2567")
/// @returns {Real} Client handle
function colyseus_client_create(_endpoint) {
    var _client = __colyseus_gm_client_create(_endpoint);
    if (_client > 0) {
        __colyseus_auth_restore(_client);
    }
    return _client;
}

// =============================================================================
// Matchmaking — wraps native join/create with struct-to-JSON conversion
// =============================================================================

/// @ignore Internal: convert options to JSON string
function __colyseus_options_to_json(_options) {
    if (is_struct(_options)) {
        return json_stringify(_options);
    }
    return string(_options);
}

/// Join or create a room.
/// @param {Real} _client  Client handle
/// @param {String} _room_name  Room name
/// @param {Struct|String} _options  Matchmaking options (struct or JSON string)
/// @returns {Real} Room reference
function colyseus_client_join_or_create(_client, _room_name, _options) {
    return __colyseus_gm_client_join_or_create(_client, _room_name, __colyseus_options_to_json(_options));
}

/// Create a room.
/// @param {Real} _client  Client handle
/// @param {String} _room_name  Room name
/// @param {Struct|String} _options  Matchmaking options (struct or JSON string)
/// @returns {Real} Room reference
function colyseus_client_create_room(_client, _room_name, _options) {
    return __colyseus_gm_client_create_room(_client, _room_name, __colyseus_options_to_json(_options));
}

/// Join a room.
/// @param {Real} _client  Client handle
/// @param {String} _room_name  Room name
/// @param {Struct|String} _options  Matchmaking options (struct or JSON string)
/// @returns {Real} Room reference
function colyseus_client_join(_client, _room_name, _options) {
    return __colyseus_gm_client_join(_client, _room_name, __colyseus_options_to_json(_options));
}

/// Join a room by ID.
/// @param {Real} _client  Client handle
/// @param {String} _room_id  Room ID
/// @param {Struct|String} _options  Matchmaking options (struct or JSON string)
/// @returns {Real} Room reference
function colyseus_client_join_by_id(_client, _room_id, _options) {
    return __colyseus_gm_client_join_by_id(_client, _room_id, __colyseus_options_to_json(_options));
}

// =============================================================================
// Room event handler registration (keyed by room ref)
// =============================================================================

/// @param {Real} _room_ref  The room reference returned by join_or_create / join / etc.
/// @param {Function} _handler  handler(room_ref)
function colyseus_on_join(_room_ref, _handler) {
    var _entry = __colyseus_get_room_entry(_room_ref);
    _entry.on_join = _handler;
}

/// @param {Real} _room_ref
/// @param {Function} _handler  handler(room_ref)
function colyseus_on_state_change(_room_ref, _handler) {
    var _entry = __colyseus_get_room_entry(_room_ref);
    _entry.on_state_change = _handler;
}

/// @param {Real} _room_ref
/// @param {Function} _handler  handler(code, message)
function colyseus_on_error(_room_ref, _handler) {
    var _entry = __colyseus_get_room_entry(_room_ref);
    _entry.on_error = _handler;
}

/// @param {Real} _room_ref
/// @param {Function} _handler  handler(code, reason)
function colyseus_on_leave(_room_ref, _handler) {
    var _entry = __colyseus_get_room_entry(_room_ref);
    _entry.on_leave = _handler;
}

/// @param {Real} _room_ref
/// @param {Function} _handler  handler(room_ref, type_string, data)
///   data is auto-decoded: struct for maps, string/number/bool for primitives, undefined for nil/binary.
function colyseus_on_message(_room_ref, _handler) {
    var _entry = __colyseus_get_room_entry(_room_ref);
    _entry.on_message = _handler;
}

/// Internal: get or create room handler entry
function __colyseus_get_room_entry(_room_ref) {
    if (!ds_map_exists(global.__colyseus_room_handlers, _room_ref)) {
        ds_map_set(global.__colyseus_room_handlers, _room_ref, {});
    }
    return ds_map_find_value(global.__colyseus_room_handlers, _room_ref);
}

// =============================================================================
// Schema callback wrappers — register native callback + store GML handler
// =============================================================================

/// Listen for property changes: handler(value, previous_value)
/// Usage: colyseus_listen(callbacks, "field", handler)          — listens on root state
///        colyseus_listen(callbacks, instance, "field", handler) — listens on a child instance
function colyseus_listen(_callbacks, _instance_or_property, _property_or_handler, _handler = undefined) {
    var _parent_handle, _field;
    if (is_string(_instance_or_property)) {
        // Root shorthand: colyseus_listen(callbacks, "field", handler)
        _handler = _property_or_handler;
        _field = _instance_or_property;
        _parent_handle = 0;  // resolved at C level to root state
        var _handle = colyseus_callbacks_listen(_callbacks, 0, _field);
    } else {
        // Full form: colyseus_listen(callbacks, instance, "field", handler)
        _parent_handle = is_struct(_instance_or_property) ? _instance_or_property.__handle : _instance_or_property;
        _field = _property_or_handler;
        var _handle = colyseus_callbacks_listen(_callbacks, _parent_handle, _field);
    }
    if (_handle >= 0) {
        global.__colyseus_schema_handlers[_handle] = _handler;
        global.__colyseus_schema_meta[_handle] = { parent_handle: _parent_handle, field: _field };
    }
    return _handle;
}

/// Listen for items added to a collection: handler(instance_handle, key)
/// Usage: colyseus_on_add(callbacks, "field", handler)          — listens on root state
///        colyseus_on_add(callbacks, instance, "field", handler) — listens on a child instance
function colyseus_on_add(_callbacks, _instance_or_property, _property_or_handler, _handler = undefined) {
    if (is_string(_instance_or_property)) {
        _handler = _property_or_handler;
        var _handle = colyseus_callbacks_on_add(_callbacks, 0, _instance_or_property);
    } else {
        var _inst = is_struct(_instance_or_property) ? _instance_or_property.__handle : _instance_or_property;
        var _handle = colyseus_callbacks_on_add(_callbacks, _inst, _property_or_handler);
    }
    if (_handle >= 0) {
        global.__colyseus_schema_handlers[_handle] = _handler;
    }
    return _handle;
}

/// Listen for items removed from a collection: handler(instance_handle, key)
/// Usage: colyseus_on_remove(callbacks, "field", handler)          — listens on root state
///        colyseus_on_remove(callbacks, instance, "field", handler) — listens on a child instance
function colyseus_on_remove(_callbacks, _instance_or_property, _property_or_handler, _handler = undefined) {
    if (is_string(_instance_or_property)) {
        _handler = _property_or_handler;
        var _handle = colyseus_callbacks_on_remove(_callbacks, 0, _instance_or_property);
    } else {
        var _inst = is_struct(_instance_or_property) ? _instance_or_property.__handle : _instance_or_property;
        var _handle = colyseus_callbacks_on_remove(_callbacks, _inst, _property_or_handler);
    }
    if (_handle >= 0) {
        global.__colyseus_schema_handlers[_handle] = _handler;
    }
    return _handle;
}

// =============================================================================
// Schema field access — unified getter
// =============================================================================

/// Get the type of a field on a schema instance.
/// @param {Real|Struct} _instance  Schema instance handle or struct
/// @param {String} _field  Field name
/// @returns {Real} COLYSEUS_TYPE_* constant, or -1 if not found
function colyseus_schema_get_field_type(_instance, _field) {
    if (is_struct(_instance)) {
        _instance = _instance.__handle;
    }
    return __colyseus_schema_get_field_type(_instance, _field);
}

/// Get a field value from a schema instance, auto-dispatching by type.
/// Returns: string for string fields, number for numeric/bool fields,
///          struct for ref fields (synchronized), undefined if unknown.
/// @param {Real|Struct} _instance  Schema instance handle or struct
/// @param {String} _field   Field name
function colyseus_schema_get(_instance, _field) {
    // Allow passing a struct returned by a previous colyseus_schema_get call
    if (is_struct(_instance)) {
        _instance = _instance.__handle;
    }
    var _type = __colyseus_schema_get(_instance, _field);
    if (_type == COLYSEUS_TYPE_STRING) {
        return __colyseus_schema_get_result_string();
    } else if (_type < 0) {
        return undefined;
    } else if (_type == COLYSEUS_TYPE_REF) {
        var _handle = __colyseus_schema_get_result_number();
        if (_handle == 0) return undefined;
        return __colyseus_schema_to_struct(_handle);
    } else {
        return __colyseus_schema_get_result_number();
    }
}

/// @ignore Internal: Build or retrieve a cached GML struct for a schema instance handle.
/// The struct is kept in sync — fields are refreshed on each state change.
function __colyseus_schema_to_struct(_handle) {
    // Return cached struct if available
    if (ds_map_exists(global.__colyseus_schema_structs, _handle)) {
        return ds_map_find_value(global.__colyseus_schema_structs, _handle);
    }

    var _struct = {};
    _struct.__handle = _handle;
    _struct.__room_ref = global.__colyseus_current_room_ref;
    ds_map_set(global.__colyseus_schema_structs, _handle, _struct);

    // Populate fields from C data
    __colyseus_schema_refresh_struct(_handle, _struct);
    return _struct;
}

/// @ignore Internal: Refresh a GML struct's fields from the current C schema data.
function __colyseus_schema_refresh_struct(_handle, _struct) {
    var _count = __colyseus_schema_field_count(_handle);
    for (var _i = 0; _i < _count; _i++) {
        var _name = __colyseus_schema_field_name(_handle, _i);
        var _ftype = __colyseus_schema_field_type_at(_handle, _i);
        if (_name == "") continue;

        if (_ftype == COLYSEUS_TYPE_STRING) {
            variable_struct_set(_struct, _name, __colyseus_schema_get_string(_handle, _name));
        } else if (_ftype == COLYSEUS_TYPE_REF) {
            var _ref = __colyseus_schema_get_number(_handle, _name);
            if (_ref != 0) {
                variable_struct_set(_struct, _name, __colyseus_schema_to_struct(_ref));
            } else {
                variable_struct_set(_struct, _name, undefined);
            }
        } else if (_ftype >= 0) {
            variable_struct_set(_struct, _name, __colyseus_schema_get_number(_handle, _name));
        }
    }
}

/// Free a room and clear cached schema structs belonging to it.
/// @param {Real} _room_ref  Room reference
function colyseus_room_free(_room_ref) {
    var _key = ds_map_find_first(global.__colyseus_schema_structs);
    while (_key != undefined) {
        var _next = ds_map_find_next(global.__colyseus_schema_structs, _key);
        var _s = ds_map_find_value(global.__colyseus_schema_structs, _key);
        if (is_struct(_s) && _s.__room_ref == _room_ref) {
            ds_map_delete(global.__colyseus_schema_structs, _key);
        }
        _key = _next;
    }
    __colyseus_room_free(_room_ref);
}

/// Get room state as a synchronized struct.
/// All schema fields are populated, including nested refs.
/// The struct is automatically refreshed on each state change.
/// @param {Real} _room_ref  Room reference
/// @returns {Struct}
function colyseus_room_get_state(_room_ref) {
    global.__colyseus_current_room_ref = _room_ref;
    var _handle = __colyseus_room_get_state(_room_ref);
    if (_handle == 0) return undefined;
    return __colyseus_schema_to_struct(_handle);
}

/// Get an item from a MapSchema field by key. Returns a struct for schema items.
/// @param {Real|Struct} _instance  Schema instance handle or struct
/// @param {String} _field  Map field name
/// @param {String} _key  Map key
/// @returns {Struct|Undefined}
function colyseus_map_get(_instance, _field, _key) {
    if (is_struct(_instance)) {
        _instance = _instance.__handle;
    }
    var _handle = __colyseus_map_get(_instance, _field, _key);
    if (_handle == 0) return undefined;
    return __colyseus_schema_to_struct(_handle);
}

// =============================================================================
// Message sending helper
// =============================================================================

/// Send a value as a message to the room.
/// Supports: structs (sent as map), booleans, numbers, and strings.
/// Examples:
///   colyseus_send(room, "move", { x: 10, y: 20 });
///   colyseus_send(room, "shoot", true);
///   colyseus_send(room, "target", 90);
///   colyseus_send(room, "name", "player1");
function colyseus_send(_room_ref, _type, _data) {
    var _msg;
    if (is_struct(_data)) {
        _msg = colyseus_message_create_map();
        var _keys = variable_struct_get_names(_data);
        for (var _i = 0; _i < array_length(_keys); _i++) {
            var _key = _keys[_i];
            var _val = variable_struct_get(_data, _key);
            if (is_string(_val)) {
                colyseus_message_put_str(_msg, _key, _val);
            } else if (is_bool(_val)) {
                colyseus_message_put_bool(_msg, _key, _val);
            } else {
                colyseus_message_put_number(_msg, _key, _val);
            }
        }
    } else if (is_bool(_data)) {
        _msg = colyseus_message_create_bool(_data);
    } else if (is_string(_data)) {
        _msg = colyseus_message_create_string(_data);
    } else if (is_numeric(_data)) {
        if (_data == floor(_data)) {
            _msg = colyseus_message_create_int(_data);
        } else {
            _msg = colyseus_message_create_number(_data);
        }
    } else {
        show_debug_message("colyseus_send: unsupported data type for message '" + _type + "'");
        return;
    }
    colyseus_room_send_message(_room_ref, _type, _msg);
}

// =============================================================================
// HTTP requests — callback(err, response) style
// =============================================================================

/// Perform an HTTP GET request.
/// @param {Real} _client  Client handle
/// @param {String} _path  Request path (e.g., "/api/leaderboard")
/// @param {Function} _callback  callback(err, response) — err is undefined on success, response is the parsed body
function colyseus_http_get(_client, _path, _callback) {
    var _handle = __colyseus_gm_http_get(_client, _path);
    if (_handle > 0) {
        ds_map_set(global.__colyseus_http_handlers, _handle, _callback);
    }
    return _handle;
}

/// Perform an HTTP POST request.
/// @param {Real} _client  Client handle
/// @param {String} _path  Request path
/// @param {Struct} _body  Request body (struct will be JSON-encoded, string sent as-is)
/// @param {Function} _callback  callback(err, response)
function colyseus_http_post(_client, _path, _body, _callback) {
    var _json = is_struct(_body) ? json_stringify(_body) : string(_body);
    var _handle = __colyseus_gm_http_post(_client, _path, _json);
    if (_handle > 0) {
        ds_map_set(global.__colyseus_http_handlers, _handle, _callback);
    }
    return _handle;
}

/// Perform an HTTP PUT request.
/// @param {Real} _client  Client handle
/// @param {String} _path  Request path
/// @param {Struct} _body  Request body (struct will be JSON-encoded, string sent as-is)
/// @param {Function} _callback  callback(err, response)
function colyseus_http_put(_client, _path, _body, _callback) {
    var _json = is_struct(_body) ? json_stringify(_body) : string(_body);
    var _handle = __colyseus_gm_http_put(_client, _path, _json);
    if (_handle > 0) {
        ds_map_set(global.__colyseus_http_handlers, _handle, _callback);
    }
    return _handle;
}

/// Perform an HTTP DELETE request.
/// @param {Real} _client  Client handle
/// @param {String} _path  Request path
/// @param {Function} _callback  callback(err, response)
function colyseus_http_delete(_client, _path, _callback) {
    var _handle = __colyseus_gm_http_delete(_client, _path);
    if (_handle > 0) {
        ds_map_set(global.__colyseus_http_handlers, _handle, _callback);
    }
    return _handle;
}

/// Perform an HTTP PATCH request.
/// @param {Real} _client  Client handle
/// @param {String} _path  Request path
/// @param {Struct} _body  Request body (struct will be JSON-encoded, string sent as-is)
/// @param {Function} _callback  callback(err, response)
function colyseus_http_patch(_client, _path, _body, _callback) {
    var _json = is_struct(_body) ? json_stringify(_body) : string(_body);
    var _handle = __colyseus_gm_http_patch(_client, _path, _json);
    if (_handle > 0) {
        ds_map_set(global.__colyseus_http_handlers, _handle, _callback);
    }
    return _handle;
}

/// Set auth token for HTTP requests (sent as Bearer token).
/// Automatically persists the token to disk for future sessions.
/// @param {Real} _client  Client handle
/// @param {String} _token  Auth token
function colyseus_auth_set_token(_client, _token) {
    __colyseus_gm_auth_set_token(_client, _token);
    __colyseus_auth_save(_token);
}

/// Get current auth token.
/// @param {Real} _client  Client handle
/// @returns {String}
function colyseus_auth_get_token(_client) {
    return __colyseus_gm_auth_get_token(_client);
}

/// Clear the persisted auth token (e.g., on logout).
function colyseus_auth_clear_token(_client) {
    __colyseus_gm_auth_set_token(_client, "");
    if (file_exists(__COLYSEUS_AUTH_FILE)) {
        file_delete(__COLYSEUS_AUTH_FILE);
    }
}

/// @ignore Internal: save auth token to disk
function __colyseus_auth_save(_token) {
    var _map = ds_map_create();
    ds_map_set(_map, "token", _token);
    ds_map_secure_save(_map, __COLYSEUS_AUTH_FILE);
    ds_map_destroy(_map);
}

/// @ignore Internal: restore auth token from disk
function __colyseus_auth_restore(_client) {
    if (!file_exists(__COLYSEUS_AUTH_FILE)) return;
    var _map = ds_map_secure_load(__COLYSEUS_AUTH_FILE);
    if (_map == -1) return;
    var _token = ds_map_find_value(_map, "token");
    if (is_string(_token) && _token != "") {
        __colyseus_gm_auth_set_token(_client, _token);
    }
    ds_map_destroy(_map);
}

// =============================================================================
// Message decoding helper — auto-decode received message into GML value
// =============================================================================

/// @returns {Struct|String|Real|Bool|Undefined}
function __colyseus_decode_message() {
    var _msg_type = colyseus_message_get_type();

    switch (_msg_type) {
        case COLYSEUS_MSG_MAP:
            var _struct = {};
            colyseus_message_iter_begin();
            while (colyseus_message_iter_next()) {
                var _key = colyseus_message_iter_key();
                var _vtype = colyseus_message_iter_value_type();
                if (_vtype == COLYSEUS_MSG_STR) {
                    variable_struct_set(_struct, _key, colyseus_message_iter_value_string());
                } else if (_vtype == COLYSEUS_MSG_BOOL) {
                    variable_struct_set(_struct, _key, colyseus_message_iter_value_number() > 0.5);
                } else {
                    variable_struct_set(_struct, _key, colyseus_message_iter_value_number());
                }
            }
            return _struct;

        case COLYSEUS_MSG_STR:
            return colyseus_message_read_string_value();

        case COLYSEUS_MSG_INT:
        case COLYSEUS_MSG_UINT:
        case COLYSEUS_MSG_FLOAT:
            return colyseus_message_read_number_value();

        case COLYSEUS_MSG_BOOL:
            return colyseus_message_read_number_value() > 0.5;

        default:
            return undefined;
    }
}

// =============================================================================
// Event processing — polls all events and dispatches to registered handlers
// =============================================================================

/// Poll and dispatch all queued Colyseus events. Call once per frame in Step.
function colyseus_process() {
    var _evt = colyseus_poll_event();

    while (_evt != COLYSEUS_EVENT_NONE) {
        var _room_ref = colyseus_event_get_room();
        global.__colyseus_current_room_ref = _room_ref;
        var _entry = ds_map_exists(global.__colyseus_room_handlers, _room_ref)
            ? ds_map_find_value(global.__colyseus_room_handlers, _room_ref)
            : undefined;

        switch (_evt) {
            case COLYSEUS_EVENT_ROOM_JOIN:
                if (_entry != undefined && variable_struct_exists(_entry, "on_join")) {
                    _entry.on_join(_room_ref);
                }
                break;

            case COLYSEUS_EVENT_STATE_CHANGE:
                if (_entry != undefined && variable_struct_exists(_entry, "on_state_change")) {
                    _entry.on_state_change(_room_ref);
                }
                break;

            case COLYSEUS_EVENT_ROOM_MESSAGE:
                if (_entry != undefined && variable_struct_exists(_entry, "on_message")) {
                    _entry.on_message(
                        _room_ref,
                        colyseus_event_get_message(),
                        __colyseus_decode_message()
                    );
                }
                break;

            case COLYSEUS_EVENT_ROOM_ERROR:
                if (_entry != undefined && variable_struct_exists(_entry, "on_error")) {
                    _entry.on_error(
                        colyseus_event_get_code(),
                        colyseus_event_get_message()
                    );
                }
                break;

            case COLYSEUS_EVENT_CLIENT_ERROR:
                show_debug_message("Colyseus client error [" + string(colyseus_event_get_code()) + "]: " + colyseus_event_get_message());
                if (_entry != undefined && variable_struct_exists(_entry, "on_error")) {
                    _entry.on_error(
                        colyseus_event_get_code(),
                        colyseus_event_get_message()
                    );
                }
                break;

            case COLYSEUS_EVENT_ROOM_LEAVE:
                if (_entry != undefined && variable_struct_exists(_entry, "on_leave")) {
                    _entry.on_leave(
                        colyseus_event_get_code(),
                        colyseus_event_get_message()
                    );
                }
                break;

            case COLYSEUS_EVENT_PROPERTY_CHANGE:
                var _cb = colyseus_event_get_callback_handle();
                var _handler = global.__colyseus_schema_handlers[_cb];
                if (_handler != undefined) {
                    var _type = colyseus_event_get_value_type();
                    var _val, _prev;
                    if (_type == COLYSEUS_TYPE_STRING) {
                        _val = colyseus_event_get_value_string();
                        _prev = colyseus_event_get_prev_value_string();
                    } else if (_type == COLYSEUS_TYPE_REF) {
                        var _ref = colyseus_event_get_instance();
                        _val = (_ref != 0) ? __colyseus_schema_to_struct(_ref) : undefined;
                        _prev = undefined;
                    } else {
                        _val = colyseus_event_get_value_number();
                        _prev = colyseus_event_get_prev_value_number();
                    }

                    // Update cached struct field inline
                    var _meta = global.__colyseus_schema_meta[_cb];
                    if (_meta != undefined) {
                        var _parent = _meta.parent_handle;
                        if (ds_map_exists(global.__colyseus_schema_structs, _parent)) {
                            variable_struct_set(
                                ds_map_find_value(global.__colyseus_schema_structs, _parent),
                                _meta.field,
                                _val
                            );
                        }
                    }

                    _handler(_val, _prev);
                }
                break;

            case COLYSEUS_EVENT_ITEM_ADD:
                var _cb = colyseus_event_get_callback_handle();
                var _handler = global.__colyseus_schema_handlers[_cb];
                if (_handler != undefined) {
                    var _ref = colyseus_event_get_instance();
                    _handler(
                        (_ref != 0) ? __colyseus_schema_to_struct(_ref) : _ref,
                        colyseus_event_get_key_string()
                    );
                }
                break;

            case COLYSEUS_EVENT_ITEM_REMOVE:
                var _cb = colyseus_event_get_callback_handle();
                var _handler = global.__colyseus_schema_handlers[_cb];
                if (_handler != undefined) {
                    var _ref = colyseus_event_get_instance();
                    _handler(
                        (_ref != 0) ? __colyseus_schema_to_struct(_ref) : _ref,
                        colyseus_event_get_key_string()
                    );
                    // Clean up cached struct for the removed instance
                    if (_ref != 0 && ds_map_exists(global.__colyseus_schema_structs, _ref)) {
                        ds_map_delete(global.__colyseus_schema_structs, _ref);
                    }
                }
                break;

            case COLYSEUS_EVENT_HTTP_RESPONSE:
                var _cb = colyseus_event_get_callback_handle();
                if (ds_map_exists(global.__colyseus_http_handlers, _cb)) {
                    var _handler = ds_map_find_value(global.__colyseus_http_handlers, _cb);
                    ds_map_delete(global.__colyseus_http_handlers, _cb);
                    var _body = __colyseus_gm_event_get_http_body();
                    var _response = undefined;
                    try { _response = json_parse(_body); }
                    catch (_e) { _response = _body; }
                    _handler(undefined, _response);
                }
                break;

            case COLYSEUS_EVENT_HTTP_ERROR:
                var _cb = colyseus_event_get_callback_handle();
                if (ds_map_exists(global.__colyseus_http_handlers, _cb)) {
                    var _handler = ds_map_find_value(global.__colyseus_http_handlers, _cb);
                    ds_map_delete(global.__colyseus_http_handlers, _cb);
                    var _err = {
                        code: colyseus_event_get_code(),
                        message: colyseus_event_get_message()
                    };
                    _handler(_err, undefined);
                }
                break;
        }

        _evt = colyseus_poll_event();
    }
}
