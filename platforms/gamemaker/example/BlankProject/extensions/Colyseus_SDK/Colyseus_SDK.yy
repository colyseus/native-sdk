{
  "$GMExtension": "",
  "%Name": "Colyseus_SDK",
  "androidactivityinject": null,
  "androidclassname": "",
  "androidcodeinjection": "",
  "androidinject": null,
  "androidmanifestinject": null,
  "androidPermissions": [],
  "androidProps": false,
  "androidsourcedir": "",
  "author": "",
  "classname": "",
  "copyToTargets": 3026418979657744622,
  "description": "",
  "exportToGame": true,
  "extensionVersion": "0.17.0",
  "files": [
    {
      "$GMExtensionFile": "v1",
      "%Name": "",
      "constants": [],
      "copyToTargets": -1,
      "filename": "libcolyseus.dylib",
      "final": "",
      "functions": [
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_is_ready",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_is_ready",
          "help": "(internal) is ready",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_is_ready",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_create",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_create",
          "help": "(internal) Create Colyseus SDK Client Instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_client_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_free",
          "help": "Free Colyseus SDK Client Instance",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_client_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_join_or_create",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_join_or_create",
          "help": "(internal) Join or create a room",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_join_or_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_create_room",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_create_room",
          "help": "(internal) Create a room",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_create_room",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_join",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_join",
          "help": "(internal) Join a room",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_join",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_join_by_id",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_join_by_id",
          "help": "(internal) Join a room by ID",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_join_by_id",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_client_reconnect",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_reconnect",
          "help": "Reconnect to a room",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_client_reconnect",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_leave",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_leave",
          "help": "Leave a room",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_leave",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_room_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_free",
          "help": "(internal) Free a room",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_room_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_send",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_send",
          "help": "Send a message to the room",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_send",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_send_bytes",
          "argCount": 4,
          "args": [
            2,
            1,
            3,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_send_bytes",
          "help": "Send a message to the room with raw bytes",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_send_bytes",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_send_int",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_send_int",
          "help": "Send a message to the room with integer type",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_send_int",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_get_id",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_get_id",
          "help": "Get room ID",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_get_id",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_get_session_id",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_get_session_id",
          "help": "Get room session ID",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_get_session_id",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_get_name",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_get_name",
          "help": "Get room name",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_get_name",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_is_connected",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_is_connected",
          "help": "Check if room is connected",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_is_connected",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_is_reconnecting",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_is_reconnecting",
          "help": "Whether the room is currently inside an automatic reconnection cycle",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_is_reconnecting",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_set_reconnection_options",
          "argCount": 8,
          "args": [
            2,
            2,
            2,
            2,
            2,
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_set_reconnection_options",
          "help": "Configure automatic reconnection (pass -1 to keep current values; enabled: 0=off, 1=on)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_set_reconnection_options",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_room_get_state",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_get_state",
          "help": "(internal) Get room state instance handle",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_room_get_state",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_string",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_string",
          "help": "(internal) Get string field from schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_field_type",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_field_type",
          "help": "(internal) Get field type enum from schema instance (-1 if not found)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_field_type",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_number",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_number",
          "help": "(internal) Get number/ref/collection handle from schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get",
          "help": "(internal) Unified get - returns field type, stores result internally",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_result_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_result_string",
          "help": "(internal) Get string result from last __colyseus_schema_get call",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_result_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_result_number",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_result_number",
          "help": "(internal) Get number result from last __colyseus_schema_get call",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_result_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_field_count",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_field_count",
          "help": "(internal) Get number of fields in a schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_field_count",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_field_name",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_field_name",
          "help": "(internal) Get field name by index from schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_field_name",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_field_type_at",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_field_type_at",
          "help": "(internal) Get field type by index from schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_field_type_at",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_map_get",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_map_get",
          "help": "(internal) Get item handle from map by key",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_map_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_create",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_create",
          "help": "Create callbacks manager for a room",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_free",
          "help": "Free callbacks manager",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_remove_handle",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_remove_handle",
          "help": "Remove a specific callback",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_remove_handle",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_listen",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_listen",
          "help": "Listen for property changes on a schema instance",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_listen",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_on_add",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_on_add",
          "help": "Listen for items added to a collection",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_on_add",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_on_remove",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_on_remove",
          "help": "Listen for items removed from a collection",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_on_remove",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_on_change_instance",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_on_change_instance",
          "help": "Listen for any property change on a schema instance",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_on_change_instance",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_on_change_collection",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_on_change_collection",
          "help": "Listen for item changes in a collection",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_on_change_collection",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_poll_event",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_poll_event",
          "help": "Poll for next event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_poll_event",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_room",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_room",
          "help": "Get room handle from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_room",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_code",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_code",
          "help": "Get error/leave code from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_code",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_message",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_message",
          "help": "Get message/error/reason from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_message",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_data",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_data",
          "help": "Get message data from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_data",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_data_length",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_data_length",
          "help": "Get message data length from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_data_length",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_callback_handle",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_callback_handle",
          "help": "Get callback handle from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_callback_handle",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_instance",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_instance",
          "help": "Get schema instance handle from event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_instance",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_value_number",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_value_number",
          "help": "Get numeric value from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_value_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_value_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_value_string",
          "help": "Get string value from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_value_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_prev_value_number",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_prev_value_number",
          "help": "Get previous numeric value from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_prev_value_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_prev_value_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_prev_value_string",
          "help": "Get previous string value from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_prev_value_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_key_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_key_string",
          "help": "Get key string from collection event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_key_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_value_type",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_value_type",
          "help": "Get field type from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_value_type",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_map",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_map",
          "help": "Create a map message for sending",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_map",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_put_str",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_put_str",
          "help": "Put a string field in a message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_put_str",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_put_number",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_put_number",
          "help": "Put a number field in a message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_put_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_put_bool",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_put_bool",
          "help": "Put a bool field in a message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_put_bool",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_free",
          "help": "Free a message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_send_message",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_send_message",
          "help": "Send a message to the room (sends and frees the message)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_send_message",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_bool",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_bool",
          "help": "Create a message with a boolean value",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_bool",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_number",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_number",
          "help": "Create a message with a float number value",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_int",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_int",
          "help": "Create a message with an integer value",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_int",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_string",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_string",
          "help": "Create a message with a string value",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_get_type",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_get_type",
          "help": "Get message payload type (map, string, number, etc.)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_get_type",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_string",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_string",
          "help": "Read a string field from received message by key",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_number",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_number",
          "help": "Read a number field from received message by key",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_bool",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_bool",
          "help": "Read a bool field from received message by key",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_bool",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_string_value",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_string_value",
          "help": "Read primitive string value from received message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_string_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_number_value",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_number_value",
          "help": "Read primitive number value from received message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_number_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_map_size",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_map_size",
          "help": "Get number of entries in received map message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_map_size",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_begin",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_begin",
          "help": "Begin iterating over received map message entries",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_begin",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_next",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_next",
          "help": "Advance to next map entry (returns 1 if valid, 0 if done)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_next",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_key",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_key",
          "help": "Get current iterator key string",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_key",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_value_type",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_value_type",
          "help": "Get current iterator value type (COLYSEUS_MSG_* constant)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_value_type",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_value_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_value_string",
          "help": "Get current iterator value as string",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_value_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_value_number",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_value_number",
          "help": "Get current iterator value as number",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_value_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_get",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_get",
          "help": "(internal) HTTP GET request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_post",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_post",
          "help": "(internal) HTTP POST request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_post",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_put",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_put",
          "help": "(internal) HTTP PUT request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_put",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_delete",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_delete",
          "help": "(internal) HTTP DELETE request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_delete",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_patch",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_patch",
          "help": "(internal) HTTP PATCH request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_patch",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_auth_set_token",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_auth_set_token",
          "help": "(internal) Set HTTP auth token",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_auth_set_token",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_auth_get_token",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_auth_get_token",
          "help": "(internal) Get HTTP auth token",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_auth_get_token",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_event_get_http_status",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_http_status",
          "help": "(internal) Get HTTP status code from event",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_event_get_http_status",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_event_get_http_body",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_http_body",
          "help": "(internal) Get HTTP response body from event",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_event_get_http_body",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_get_latency",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_get_latency",
          "help": "(internal) Measure latency to an endpoint",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_get_latency",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_select_by_latency",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_select_by_latency",
          "help": "(internal) Select lowest-latency endpoint",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_select_by_latency",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_latency",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_latency",
          "help": "Get latency (ms) from the current latency event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_latency",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_push_response",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_push_response",
          "help": "(internal) Push HTTP response event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_push_response",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_push_error",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_push_error",
          "help": "(internal) Push HTTP error event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_push_error",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_latency_push_response",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_latency_push_response",
          "help": "(internal) Push latency success event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_latency_push_response",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_latency_push_error",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_latency_push_error",
          "help": "(internal) Push latency error event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_latency_push_error",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_latency_push_selected",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_latency_push_selected",
          "help": "(internal) Push latency selection event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_latency_push_selected",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_get_endpoint",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_get_endpoint",
          "help": "(internal) http get endpoint",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_get_endpoint",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_abi_version",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_predict_abi_version",
          "help": "(internal) predict abi version",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_abi_version",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_now",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_now",
          "help": "(internal) now",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_now",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_clock_stat",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_clock_stat",
          "help": "(internal) clock stat",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_clock_stat",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_reconnect_poll",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_reconnect_poll",
          "help": "(internal) reconnect poll",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_reconnect_poll",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_init",
          "argCount": 4,
          "args": [
            2,
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_init",
          "help": "(internal) input init",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_init",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_set",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_set",
          "help": "(internal) input set",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_set",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_get",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_get",
          "help": "(internal) input get",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_send",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_send",
          "help": "(internal) input send",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_send",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_stat",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_stat",
          "help": "(internal) input stat",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_stat",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_set_render_delay",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_set_render_delay",
          "help": "(internal) input set render delay",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_set_render_delay",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_reset",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_reset",
          "help": "(internal) input reset",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_reset",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_set_rewind_field",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_set_rewind_field",
          "help": "(internal) input set rewind field",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_set_rewind_field",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_create",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_create",
          "help": "(internal) predict create",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_create_with",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_create_with",
          "help": "(internal) predict create with",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_create_with",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_free",
          "help": "(internal) predict free",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_tick",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_tick",
          "help": "(internal) predict tick",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_tick",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_attach",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_attach",
          "help": "(internal) predict attach",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_attach",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_attach_all",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_attach_all",
          "help": "(internal) predict attach all",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_attach_all",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_attach_reckon",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_attach_reckon",
          "help": "(internal) predict attach reckon",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_attach_reckon",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_attach_all_reckon",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_attach_all_reckon",
          "help": "(internal) predict attach all reckon",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_attach_all_reckon",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_detach",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_detach",
          "help": "(internal) predict detach",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_detach",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_value",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_value",
          "help": "(internal) predict value",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_value_at",
          "argCount": 4,
          "args": [
            2,
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_value_at",
          "help": "(internal) predict value at",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_value_at",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_reconciler",
          "argCount": 4,
          "args": [
            2,
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_reconciler",
          "help": "(internal) predict reconciler",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_reconciler",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_sim_begin",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_sim_begin",
          "help": "(internal) sim begin",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_sim_begin",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_sim_part",
          "argCount": 2,
          "args": [
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_sim_part",
          "help": "(internal) sim part",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_sim_part",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_sim_create",
          "argCount": 5,
          "args": [
            2,
            2,
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_sim_create",
          "help": "(internal) sim create",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_sim_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_sim_part_mirror",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_sim_part_mirror",
          "help": "(internal) sim part mirror",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_sim_part_mirror",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_free",
          "help": "(internal) recon free",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_pump_begin",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_pump_begin",
          "help": "(internal) recon pump begin",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_pump_begin",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_pump_next",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_pump_next",
          "help": "(internal) recon pump next",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_pump_next",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_pump_commit",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_pump_commit",
          "help": "(internal) recon pump commit",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_pump_commit",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_pump_end",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_pump_end",
          "help": "(internal) recon pump end",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_pump_end",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_ctx",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_ctx",
          "help": "(internal) step ctx",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_ctx",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_cmd",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_cmd",
          "help": "(internal) step cmd",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_cmd",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_value",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_value",
          "help": "(internal) recon value",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_state",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_state",
          "help": "(internal) recon state",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_state",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_stat",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_stat",
          "help": "(internal) recon stat",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_stat",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_last_correction",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_last_correction",
          "help": "(internal) recon last correction",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_last_correction",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_reset",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_reset",
          "help": "(internal) recon reset",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_reset",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_mirror_set",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_mirror_set",
          "help": "(internal) mirror set",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_mirror_set",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_mirror_get",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_mirror_get",
          "help": "(internal) mirror get",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_mirror_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_memo_peek",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_memo_peek",
          "help": "(internal) step memo peek",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_memo_peek",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_memo_store",
          "argCount": 2,
          "args": [
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_memo_store",
          "help": "(internal) step memo store",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_memo_store",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_create",
          "argCount": 4,
          "args": [
            2,
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_create",
          "help": "(internal) events create",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_free",
          "help": "(internal) events free",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_drive_events",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_drive_events",
          "help": "(internal) predict drive events",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_drive_events",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_predict",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_predict",
          "help": "(internal) events predict",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_predict",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_predict",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_predict",
          "help": "(internal) step predict",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_predict",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_confirm",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_confirm",
          "help": "(internal) events confirm",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_confirm",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_reject",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_reject",
          "help": "(internal) events reject",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_reject",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_has",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_has",
          "help": "(internal) events has",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_has",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_pending",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_pending",
          "help": "(internal) events pending",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_pending",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_clear",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_clear",
          "help": "(internal) events clear",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_clear",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_create",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_create",
          "help": "(internal) spawns create",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_free",
          "help": "(internal) spawns free",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_bind_spawns",
          "argCount": 4,
          "args": [
            2,
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_bind_spawns",
          "help": "(internal) predict bind spawns",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_bind_spawns",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_spawn_set",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_spawn_set",
          "help": "(internal) spawns spawn set",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_spawn_set",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_spawn",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_spawn",
          "help": "(internal) spawns spawn",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_spawn",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_cancel",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_cancel",
          "help": "(internal) spawns cancel",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_cancel",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_accept",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_accept",
          "help": "(internal) spawns accept",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_accept",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_size",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_size",
          "help": "(internal) spawns size",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_size",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_alive",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_alive",
          "help": "(internal) spawns alive",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_alive",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_handle_add",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_handle_add",
          "help": "(internal) spawns handle add",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_handle_add",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_handle_remove",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_handle_remove",
          "help": "(internal) spawns handle remove",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_handle_remove",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_tick",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_tick",
          "help": "(internal) spawns tick",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_tick",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_iter_begin",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_iter_begin",
          "help": "(internal) spawns iter begin",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_iter_begin",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_iter_next",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_iter_next",
          "help": "(internal) spawns iter next",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_iter_next",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_entry_stat",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_entry_stat",
          "help": "(internal) spawns entry stat",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_entry_stat",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_entry_value",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_entry_value",
          "help": "(internal) spawns entry value",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_entry_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_seek",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_seek",
          "help": "(internal) spawns seek",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_seek",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_netdelay_set",
          "argCount": 3,
          "args": [
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_netdelay_set",
          "help": "(internal) netdelay set",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_netdelay_set",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_netdelay_pump",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_netdelay_pump",
          "help": "(internal) netdelay pump",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_netdelay_pump",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_netdelay_in_flight",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_netdelay_in_flight",
          "help": "(internal) netdelay in flight",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_netdelay_in_flight",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_netdelay_drop",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_netdelay_drop",
          "help": "(internal) netdelay drop",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_netdelay_drop",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        }
      ],
      "init": "",
      "kind": 1,
      "name": "",
      "origname": "",
      "ProxyFiles": [],
      "resourceType": "GMExtensionFile",
      "resourceVersion": "2.0",
      "uncompress": false,
      "usesRunnerInterface": false
    },
    {
      "$GMExtensionFile": "v1",
      "%Name": "",
      "constants": [],
      "copyToTargets": 32,
      "filename": "colyseus_wasm.js",
      "final": "",
      "functions": [
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_is_ready",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_is_ready",
          "help": "(internal) is ready",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_is_ready",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_create",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_create",
          "help": "(internal) Create Colyseus SDK Client Instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_client_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_free",
          "help": "Free Colyseus SDK Client Instance",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_client_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_join_or_create",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_join_or_create",
          "help": "(internal) Join or create a room",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_join_or_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_create_room",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_create_room",
          "help": "(internal) Create a room",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_create_room",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_join",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_join",
          "help": "(internal) Join a room",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_join",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_client_join_by_id",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_join_by_id",
          "help": "(internal) Join a room by ID",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_client_join_by_id",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_client_reconnect",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_client_reconnect",
          "help": "Reconnect to a room",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_client_reconnect",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_leave",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_leave",
          "help": "Leave a room",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_leave",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_room_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_free",
          "help": "(internal) Free a room",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_room_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_send",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_send",
          "help": "Send a message to the room",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_send",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_send_bytes",
          "argCount": 4,
          "args": [
            2,
            1,
            3,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_send_bytes",
          "help": "Send a message to the room with raw bytes",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_send_bytes",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_send_int",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_send_int",
          "help": "Send a message to the room with integer type",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_send_int",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_get_id",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_get_id",
          "help": "Get room ID",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_get_id",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_get_session_id",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_get_session_id",
          "help": "Get room session ID",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_get_session_id",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_get_name",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_get_name",
          "help": "Get room name",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_get_name",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_is_connected",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_is_connected",
          "help": "Check if room is connected",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_is_connected",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_is_reconnecting",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_is_reconnecting",
          "help": "Whether the room is currently inside an automatic reconnection cycle",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_is_reconnecting",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_set_reconnection_options",
          "argCount": 8,
          "args": [
            2,
            2,
            2,
            2,
            2,
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_set_reconnection_options",
          "help": "Configure automatic reconnection (pass -1 to keep current values; enabled: 0=off, 1=on)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_set_reconnection_options",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_room_get_state",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_get_state",
          "help": "(internal) Get room state instance handle",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_room_get_state",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_string",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_string",
          "help": "(internal) Get string field from schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_field_type",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_field_type",
          "help": "(internal) Get field type enum from schema instance (-1 if not found)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_field_type",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_number",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_number",
          "help": "(internal) Get number/ref/collection handle from schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get",
          "help": "(internal) Unified get - returns field type, stores result internally",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_result_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_result_string",
          "help": "(internal) Get string result from last __colyseus_schema_get call",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_result_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_get_result_number",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_schema_get_result_number",
          "help": "(internal) Get number result from last __colyseus_schema_get call",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_get_result_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_field_count",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_field_count",
          "help": "(internal) Get number of fields in a schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_field_count",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_field_name",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_field_name",
          "help": "(internal) Get field name by index from schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_field_name",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_schema_field_type_at",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_schema_field_type_at",
          "help": "(internal) Get field type by index from schema instance",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_schema_field_type_at",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_map_get",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_map_get",
          "help": "(internal) Get item handle from map by key",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_map_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_create",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_create",
          "help": "Create callbacks manager for a room",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_free",
          "help": "Free callbacks manager",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_remove_handle",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_remove_handle",
          "help": "Remove a specific callback",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_remove_handle",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_listen",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_listen",
          "help": "Listen for property changes on a schema instance",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_listen",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_on_add",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_on_add",
          "help": "Listen for items added to a collection",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_on_add",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_on_remove",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_on_remove",
          "help": "Listen for items removed from a collection",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_on_remove",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_on_change_instance",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_on_change_instance",
          "help": "Listen for any property change on a schema instance",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_on_change_instance",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_callbacks_on_change_collection",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_callbacks_on_change_collection",
          "help": "Listen for item changes in a collection",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_callbacks_on_change_collection",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_poll_event",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_poll_event",
          "help": "Poll for next event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_poll_event",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_room",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_room",
          "help": "Get room handle from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_room",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_code",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_code",
          "help": "Get error/leave code from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_code",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_message",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_message",
          "help": "Get message/error/reason from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_message",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_data",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_data",
          "help": "Get message data from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_data",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_data_length",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_data_length",
          "help": "Get message data length from last polled event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_data_length",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_callback_handle",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_callback_handle",
          "help": "Get callback handle from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_callback_handle",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_instance",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_instance",
          "help": "Get schema instance handle from event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_instance",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_value_number",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_value_number",
          "help": "Get numeric value from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_value_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_value_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_value_string",
          "help": "Get string value from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_value_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_prev_value_number",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_prev_value_number",
          "help": "Get previous numeric value from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_prev_value_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_prev_value_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_prev_value_string",
          "help": "Get previous string value from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_prev_value_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_key_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_key_string",
          "help": "Get key string from collection event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_key_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_value_type",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_value_type",
          "help": "Get field type from schema event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_value_type",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_map",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_map",
          "help": "Create a map message for sending",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_map",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_put_str",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_put_str",
          "help": "Put a string field in a message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_put_str",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_put_number",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_put_number",
          "help": "Put a number field in a message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_put_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_put_bool",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_put_bool",
          "help": "Put a bool field in a message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_put_bool",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_free",
          "help": "Free a message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_room_send_message",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_room_send_message",
          "help": "Send a message to the room (sends and frees the message)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_room_send_message",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_bool",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_bool",
          "help": "Create a message with a boolean value",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_bool",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_number",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_number",
          "help": "Create a message with a float number value",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_int",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_int",
          "help": "Create a message with an integer value",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_int",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_create_string",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_create_string",
          "help": "Create a message with a string value",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_create_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_get_type",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_get_type",
          "help": "Get message payload type (map, string, number, etc.)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_get_type",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_string",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_string",
          "help": "Read a string field from received message by key",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_number",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_number",
          "help": "Read a number field from received message by key",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_bool",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_bool",
          "help": "Read a bool field from received message by key",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_bool",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_string_value",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_string_value",
          "help": "Read primitive string value from received message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_string_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_read_number_value",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_read_number_value",
          "help": "Read primitive number value from received message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_read_number_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_map_size",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_map_size",
          "help": "Get number of entries in received map message",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_map_size",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_begin",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_begin",
          "help": "Begin iterating over received map message entries",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_begin",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_next",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_next",
          "help": "Advance to next map entry (returns 1 if valid, 0 if done)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_next",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_key",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_key",
          "help": "Get current iterator key string",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_key",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_value_type",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_value_type",
          "help": "Get current iterator value type (COLYSEUS_MSG_* constant)",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_value_type",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_value_string",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_value_string",
          "help": "Get current iterator value as string",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_value_string",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_message_iter_value_number",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_message_iter_value_number",
          "help": "Get current iterator value as number",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_message_iter_value_number",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_get",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_get",
          "help": "(internal) HTTP GET request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_post",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_post",
          "help": "(internal) HTTP POST request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_post",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_put",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_put",
          "help": "(internal) HTTP PUT request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_put",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_delete",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_delete",
          "help": "(internal) HTTP DELETE request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_delete",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_patch",
          "argCount": 3,
          "args": [
            2,
            1,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_patch",
          "help": "(internal) HTTP PATCH request",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_patch",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_auth_set_token",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_auth_set_token",
          "help": "(internal) Set HTTP auth token",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_auth_set_token",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_auth_get_token",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_auth_get_token",
          "help": "(internal) Get HTTP auth token",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_auth_get_token",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_event_get_http_status",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_http_status",
          "help": "(internal) Get HTTP status code from event",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_event_get_http_status",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_event_get_http_body",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_http_body",
          "help": "(internal) Get HTTP response body from event",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_event_get_http_body",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_get_latency",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_get_latency",
          "help": "(internal) Measure latency to an endpoint",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_get_latency",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_select_by_latency",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_select_by_latency",
          "help": "(internal) Select lowest-latency endpoint",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_select_by_latency",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_event_get_latency",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_event_get_latency",
          "help": "Get latency (ms) from the current latency event",
          "hidden": false,
          "kind": 1,
          "name": "colyseus_event_get_latency",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_push_response",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_push_response",
          "help": "(internal) Push HTTP response event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_push_response",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_push_error",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_push_error",
          "help": "(internal) Push HTTP error event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_push_error",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_latency_push_response",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_latency_push_response",
          "help": "(internal) Push latency success event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_latency_push_response",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_latency_push_error",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_latency_push_error",
          "help": "(internal) Push latency error event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_latency_push_error",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_latency_push_selected",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_latency_push_selected",
          "help": "(internal) Push latency selection event into queue (for testing/WASM)",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_latency_push_selected",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_http_get_endpoint",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_http_get_endpoint",
          "help": "(internal) http get endpoint",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_http_get_endpoint",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 1
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_abi_version",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_predict_abi_version",
          "help": "(internal) predict abi version",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_abi_version",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_now",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_now",
          "help": "(internal) now",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_now",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_clock_stat",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_clock_stat",
          "help": "(internal) clock stat",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_clock_stat",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_reconnect_poll",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_reconnect_poll",
          "help": "(internal) reconnect poll",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_reconnect_poll",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_init",
          "argCount": 4,
          "args": [
            2,
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_init",
          "help": "(internal) input init",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_init",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_set",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_set",
          "help": "(internal) input set",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_set",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_get",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_get",
          "help": "(internal) input get",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_send",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_send",
          "help": "(internal) input send",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_send",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_stat",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_stat",
          "help": "(internal) input stat",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_stat",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_set_render_delay",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_set_render_delay",
          "help": "(internal) input set render delay",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_set_render_delay",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_reset",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_reset",
          "help": "(internal) input reset",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_reset",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_input_set_rewind_field",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_input_set_rewind_field",
          "help": "(internal) input set rewind field",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_input_set_rewind_field",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_create",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_create",
          "help": "(internal) predict create",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_create_with",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_create_with",
          "help": "(internal) predict create with",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_create_with",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_free",
          "help": "(internal) predict free",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_tick",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_tick",
          "help": "(internal) predict tick",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_tick",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_attach",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_attach",
          "help": "(internal) predict attach",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_attach",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_attach_all",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_attach_all",
          "help": "(internal) predict attach all",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_attach_all",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_attach_reckon",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_attach_reckon",
          "help": "(internal) predict attach reckon",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_attach_reckon",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_attach_all_reckon",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_attach_all_reckon",
          "help": "(internal) predict attach all reckon",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_attach_all_reckon",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_detach",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_detach",
          "help": "(internal) predict detach",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_detach",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_value",
          "argCount": 3,
          "args": [
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_value",
          "help": "(internal) predict value",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_value_at",
          "argCount": 4,
          "args": [
            2,
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_value_at",
          "help": "(internal) predict value at",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_value_at",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_reconciler",
          "argCount": 4,
          "args": [
            2,
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_reconciler",
          "help": "(internal) predict reconciler",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_reconciler",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_sim_begin",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_sim_begin",
          "help": "(internal) sim begin",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_sim_begin",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_sim_part",
          "argCount": 2,
          "args": [
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_sim_part",
          "help": "(internal) sim part",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_sim_part",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_sim_create",
          "argCount": 5,
          "args": [
            2,
            2,
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_sim_create",
          "help": "(internal) sim create",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_sim_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_sim_part_mirror",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_sim_part_mirror",
          "help": "(internal) sim part mirror",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_sim_part_mirror",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_free",
          "help": "(internal) recon free",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_pump_begin",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_pump_begin",
          "help": "(internal) recon pump begin",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_pump_begin",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_pump_next",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_pump_next",
          "help": "(internal) recon pump next",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_pump_next",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_pump_commit",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_pump_commit",
          "help": "(internal) recon pump commit",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_pump_commit",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_pump_end",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_pump_end",
          "help": "(internal) recon pump end",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_pump_end",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_ctx",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_ctx",
          "help": "(internal) step ctx",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_ctx",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_cmd",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_cmd",
          "help": "(internal) step cmd",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_cmd",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_value",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_value",
          "help": "(internal) recon value",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_state",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_state",
          "help": "(internal) recon state",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_state",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_stat",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_stat",
          "help": "(internal) recon stat",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_stat",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_last_correction",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_last_correction",
          "help": "(internal) recon last correction",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_last_correction",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_recon_reset",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_recon_reset",
          "help": "(internal) recon reset",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_recon_reset",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_mirror_set",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_mirror_set",
          "help": "(internal) mirror set",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_mirror_set",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_mirror_get",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_mirror_get",
          "help": "(internal) mirror get",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_mirror_get",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_memo_peek",
          "argCount": 1,
          "args": [
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_memo_peek",
          "help": "(internal) step memo peek",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_memo_peek",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_memo_store",
          "argCount": 2,
          "args": [
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_memo_store",
          "help": "(internal) step memo store",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_memo_store",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_create",
          "argCount": 4,
          "args": [
            2,
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_create",
          "help": "(internal) events create",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_free",
          "help": "(internal) events free",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_drive_events",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_drive_events",
          "help": "(internal) predict drive events",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_drive_events",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_predict",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_predict",
          "help": "(internal) events predict",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_predict",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_step_predict",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_step_predict",
          "help": "(internal) step predict",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_step_predict",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_confirm",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_confirm",
          "help": "(internal) events confirm",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_confirm",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_reject",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_reject",
          "help": "(internal) events reject",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_reject",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_has",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_has",
          "help": "(internal) events has",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_has",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_pending",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_pending",
          "help": "(internal) events pending",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_pending",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_events_clear",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_events_clear",
          "help": "(internal) events clear",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_events_clear",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_create",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_create",
          "help": "(internal) spawns create",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_create",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_free",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_free",
          "help": "(internal) spawns free",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_free",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_predict_bind_spawns",
          "argCount": 4,
          "args": [
            2,
            2,
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_predict_bind_spawns",
          "help": "(internal) predict bind spawns",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_predict_bind_spawns",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_spawn_set",
          "argCount": 3,
          "args": [
            2,
            1,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_spawn_set",
          "help": "(internal) spawns spawn set",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_spawn_set",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_spawn",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_spawn",
          "help": "(internal) spawns spawn",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_spawn",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_cancel",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_cancel",
          "help": "(internal) spawns cancel",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_cancel",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_accept",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_accept",
          "help": "(internal) spawns accept",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_accept",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_size",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_size",
          "help": "(internal) spawns size",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_size",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_alive",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_alive",
          "help": "(internal) spawns alive",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_alive",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_handle_add",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_handle_add",
          "help": "(internal) spawns handle add",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_handle_add",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_handle_remove",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_handle_remove",
          "help": "(internal) spawns handle remove",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_handle_remove",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_tick",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_tick",
          "help": "(internal) spawns tick",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_tick",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_iter_begin",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_iter_begin",
          "help": "(internal) spawns iter begin",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_iter_begin",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_iter_next",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_iter_next",
          "help": "(internal) spawns iter next",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_iter_next",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_entry_stat",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_entry_stat",
          "help": "(internal) spawns entry stat",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_entry_stat",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_entry_value",
          "argCount": 2,
          "args": [
            2,
            1
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_entry_value",
          "help": "(internal) spawns entry value",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_entry_value",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_spawns_seek",
          "argCount": 2,
          "args": [
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_spawns_seek",
          "help": "(internal) spawns seek",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_spawns_seek",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_netdelay_set",
          "argCount": 3,
          "args": [
            2,
            2,
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_netdelay_set",
          "help": "(internal) netdelay set",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_netdelay_set",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_netdelay_pump",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_netdelay_pump",
          "help": "(internal) netdelay pump",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_netdelay_pump",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_netdelay_in_flight",
          "argCount": 0,
          "args": [],
          "documentation": "",
          "externalName": "colyseus_gm_netdelay_in_flight",
          "help": "(internal) netdelay in flight",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_netdelay_in_flight",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        },
        {
          "$GMExtensionFunction": "",
          "%Name": "__colyseus_gm_netdelay_drop",
          "argCount": 1,
          "args": [
            2
          ],
          "documentation": "",
          "externalName": "colyseus_gm_netdelay_drop",
          "help": "(internal) netdelay drop",
          "hidden": true,
          "kind": 1,
          "name": "__colyseus_gm_netdelay_drop",
          "resourceType": "GMExtensionFunction",
          "resourceVersion": "2.0",
          "returnType": 2
        }
      ],
      "init": "",
      "kind": 5,
      "name": "",
      "origname": "",
      "ProxyFiles": [],
      "resourceType": "GMExtensionFile",
      "resourceVersion": "2.0",
      "uncompress": false,
      "usesRunnerInterface": false
    }
  ],
  "gradleinject": null,
  "hasConvertedCodeInjection": true,
  "helpfile": "",
  "HTML5CodeInjection": "<GM_HTML5_PreHead>\n    <script src=\"colyseus_wasm.js\"></script>\n</GM_HTML5_PreHead>",
  "html5Props": true,
  "IncludedResources": [],
  "installdir": "",
  "iosCocoaPodDependencies": "",
  "iosCocoaPods": "",
  "ioscodeinjection": "",
  "iosdelegatename": "",
  "iosplistinject": null,
  "iosProps": false,
  "iosSystemFrameworkEntries": [],
  "iosThirdPartyFrameworkEntries": [],
  "license": "",
  "maccompilerflags": "",
  "maclinkerflags": "",
  "macsourcedir": "",
  "name": "Colyseus_SDK",
  "options": [
    {
      "$GMExtensionOption": "",
      "%Name": "__extOptLabel",
      "defaultValue": "Server",
      "description": "",
      "displayName": "",
      "exportToINI": false,
      "extensionId": null,
      "guid": "e7335a15-82b1-4f91-b322-70ca935292fd",
      "hidden": false,
      "listItems": [],
      "name": "__extOptLabel",
      "optType": 5,
      "resourceType": "GMExtensionOption",
      "resourceVersion": "2.0"
    },
    {
      "$GMExtensionOption": "",
      "%Name": "endpoint",
      "defaultValue": "http://127.0.0.1:2567",
      "description": "Colyseus Server Endpoint",
      "displayName": "Endpoint",
      "exportToINI": false,
      "extensionId": null,
      "guid": "ad388ecd-211f-41cb-8de3-340874cda5e1",
      "hidden": false,
      "listItems": [],
      "name": "endpoint",
      "optType": 2,
      "resourceType": "GMExtensionOption",
      "resourceVersion": "2.0"
    }
  ],
  "optionsFile": "options.json",
  "packageId": "",
  "parent": {
    "name": "BlankProject",
    "path": "BlankProject.yyp"
  },
  "productId": "",
  "resourceType": "GMExtension",
  "resourceVersion": "2.0",
  "sourcedir": "",
  "supportedTargets": -1,
  "tvosclassname": null,
  "tvosCocoaPodDependencies": "",
  "tvosCocoaPods": "",
  "tvoscodeinjection": "",
  "tvosdelegatename": null,
  "tvosmaccompilerflags": "",
  "tvosmaclinkerflags": "",
  "tvosplistinject": null,
  "tvosProps": false,
  "tvosSystemFrameworkEntries": [],
  "tvosThirdPartyFrameworkEntries": []
}
