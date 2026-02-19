/**
 * Colyseus Bridge for Godot
 * 
 * Provides a Godot-friendly interface to the Colyseus JavaScript SDK.
 * This bridge is loaded after colyseus.js and exposes window.ColyseusGodot
 * for use with Godot's JavaScriptBridge.
 * 
 * NOTE: Results are stored in _pendingResults and read by GDScript via getResult()
 * because JavaScript values don't properly convert through callbacks.
 */

(function() {
    "use strict";

    // Value type constants for raw changes serialization
    const VALUE_UNDEFINED = 0;
    const VALUE_PRIMITIVE = 1;
    const VALUE_REF = 2;
    const VALUE_UNKNOWN = 3;

    const isSchema = (val) => typeof val?.assign === "function";

    window.ColyseusGodot = {
        _nextId: 1,
        clients: {},
        rooms: {},
        _callbacks: {},
        _pendingResults: {},  // Store results for GDScript to read

        /**
         * Create a new Colyseus client
         * @param {string} endpoint - WebSocket endpoint (e.g., "ws://localhost:2567")
         * @returns {number} Client ID
         */
        createClient: function(endpoint) {
            const id = this._nextId++;
            this.clients[id] = new Colyseus.Client(endpoint);
            console.log("ColyseusGodot: Created client", id, "for", endpoint);
            return id;
        },

        /**
         * Get client endpoint
         * @param {number} clientId 
         * @returns {string}
         */
        getEndpoint: function(clientId) {
            const client = this.clients[clientId];
            return client ? client.endpoint : "";
        },

        /**
         * Get a pending result by ID and remove it
         * @param {number} resultId
         * @returns {string} JSON string of the result
         */
        getResult: function(resultId) {
            const result = this._pendingResults[resultId];
            delete this._pendingResults[resultId];
            return result || "null";
        },

        /**
         * Join or create a room
         * @param {number} clientId 
         * @param {string} roomName 
         * @param {object} options 
         * @param {function} onSuccess - Called with resultId (number)
         * @param {function} onError - Called with resultId (number)
         */
        joinOrCreate: function(clientId, roomName, options, onSuccess, onError) {
            const self = this;
            const client = this.clients[clientId];
            
            console.log("ColyseusGodot: joinOrCreate", clientId, roomName, options);
            
            if (!client) {
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: 0, message: "Client not found"});
                onError(resultId);
                return;
            }

            client.joinOrCreate(roomName, options || {}).then(function(room) {
                const roomId = self._nextId++;
                self.rooms[roomId] = room;
                self._setupRoomCallbacks(roomId, room);
                console.log("ColyseusGodot: Joined room", roomId, room.id, room.sessionId);
                
                // Store result for GDScript to read
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({
                    error: false,
                    roomId: roomId,
                    id: room.id,
                    sessionId: room.sessionId,
                    name: room.name
                });
                onSuccess(resultId);
            }).catch(function(e) {
                console.error("ColyseusGodot: joinOrCreate error", e);
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: e.code || 0, message: e.message || String(e)});
                onError(resultId);
            });
        },

        /**
         * Create a room
         */
        create: function(clientId, roomName, options, onSuccess, onError) {
            const self = this;
            const client = this.clients[clientId];
            
            if (!client) {
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: 0, message: "Client not found"});
                onError(resultId);
                return;
            }

            client.create(roomName, options || {}).then(function(room) {
                const roomId = self._nextId++;
                self.rooms[roomId] = room;
                self._setupRoomCallbacks(roomId, room);
                
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({
                    error: false, roomId: roomId, id: room.id, sessionId: room.sessionId, name: room.name
                });
                onSuccess(resultId);
            }).catch(function(e) {
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: e.code || 0, message: e.message || String(e)});
                onError(resultId);
            });
        },

        /**
         * Join a room by name
         */
        join: function(clientId, roomName, options, onSuccess, onError) {
            const self = this;
            const client = this.clients[clientId];
            
            if (!client) {
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: 0, message: "Client not found"});
                onError(resultId);
                return;
            }

            client.join(roomName, options || {}).then(function(room) {
                const roomId = self._nextId++;
                self.rooms[roomId] = room;
                self._setupRoomCallbacks(roomId, room);
                
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({
                    error: false, roomId: roomId, id: room.id, sessionId: room.sessionId, name: room.name
                });
                onSuccess(resultId);
            }).catch(function(e) {
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: e.code || 0, message: e.message || String(e)});
                onError(resultId);
            });
        },

        /**
         * Join a room by ID
         */
        joinById: function(clientId, roomId, options, onSuccess, onError) {
            const self = this;
            const client = this.clients[clientId];
            
            if (!client) {
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: 0, message: "Client not found"});
                onError(resultId);
                return;
            }

            client.joinById(roomId, options || {}).then(function(room) {
                const id = self._nextId++;
                self.rooms[id] = room;
                self._setupRoomCallbacks(id, room);
                
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({
                    error: false, roomId: id, id: room.id, sessionId: room.sessionId, name: room.name
                });
                onSuccess(resultId);
            }).catch(function(e) {
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: e.code || 0, message: e.message || String(e)});
                onError(resultId);
            });
        },

        /**
         * Reconnect to a room
         */
        reconnect: function(clientId, reconnectionToken, onSuccess, onError) {
            const self = this;
            const client = this.clients[clientId];
            
            if (!client) {
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: 0, message: "Client not found"});
                onError(resultId);
                return;
            }

            client.reconnect(reconnectionToken).then(function(room) {
                const roomId = self._nextId++;
                self.rooms[roomId] = room;
                self._setupRoomCallbacks(roomId, room);
                
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({
                    error: false, roomId: roomId, id: room.id, sessionId: room.sessionId, name: room.name
                });
                onSuccess(resultId);
            }).catch(function(e) {
                const resultId = self._nextId++;
                self._pendingResults[resultId] = JSON.stringify({error: true, code: e.code || 0, message: e.message || String(e)});
                onError(resultId);
            });
        },

        /**
         * Setup internal room callbacks storage
         */
        _setupRoomCallbacks: function(roomId, room) {
            this._callbacks[roomId] = {
                onStateChange: null,
                onMessage: [],
                onLeave: null,
                onError: null,
                callbacks: Colyseus.Callbacks.get(room),  // 0.17 API
                entities: {}  // Track entities by refId for nested listening
            };
        },

        /**
         * Set room state change callback
         * @param {number} roomId 
         * @param {function} callback - Called with resultId
         */
        setOnStateChange: function(roomId, callback) {
            const self = this;
            const room = this.rooms[roomId];
            if (!room) return;

            this._callbacks[roomId].onStateChange = callback;
            
            room.onStateChange(function(state) {
                if (callback) {
                    const resultId = self._nextId++;
                    self._pendingResults[resultId] = JSON.stringify(state.toJSON ? state.toJSON() : state);
                    callback(resultId);
                }
            });
        },

        /**
         * Set room message callback
         * @param {number} roomId 
         * @param {function} callback - Called with resultId
         */
        setOnMessage: function(roomId, callback) {
            const self = this;
            const room = this.rooms[roomId];
            if (!room) return;

            this._callbacks[roomId].onMessage.push(callback);
            
            room.onMessage("*", function(type, message) {
                if (callback) {
                    const resultId = self._nextId++;
                    self._pendingResults[resultId] = JSON.stringify({type: type, data: message});
                    callback(resultId);
                }
            });
        },

        /**
         * Set room leave callback
         * @param {number} roomId 
         * @param {function} callback - Called with resultId
         */
        setOnLeave: function(roomId, callback) {
            const self = this;
            const room = this.rooms[roomId];
            if (!room) return;

            this._callbacks[roomId].onLeave = callback;
            
            room.onLeave(function(code) {
                if (callback) {
                    const resultId = self._nextId++;
                    self._pendingResults[resultId] = JSON.stringify({code: code});
                    callback(resultId);
                }
            });
        },

        /**
         * Set room error callback
         * @param {number} roomId 
         * @param {function} callback - Called with resultId
         */
        setOnError: function(roomId, callback) {
            const self = this;
            const room = this.rooms[roomId];
            if (!room) return;

            this._callbacks[roomId].onError = callback;
            
            room.onError(function(code, message) {
                if (callback) {
                    const resultId = self._nextId++;
                    self._pendingResults[resultId] = JSON.stringify({code: code, message: message || ""});
                    callback(resultId);
                }
            });
        },

        /**
         * Send a message to the room (string type)
         */
        sendMessage: function(roomId, type, dataJson) {
            const room = this.rooms[roomId];
            if (!room) return;

            const data = dataJson && dataJson !== "null" ? JSON.parse(dataJson) : undefined;
            room.send(type, data);
        },

        /**
         * Send a message to the room (integer type)
         */
        sendMessageInt: function(roomId, type, dataJson) {
            const room = this.rooms[roomId];
            if (!room) return;

            const data = dataJson && dataJson !== "null" ? JSON.parse(dataJson) : undefined;
            room.send(type, data);
        },

        /**
         * Leave the room
         */
        leave: function(roomId, consented) {
            const room = this.rooms[roomId];
            if (!room) return;

            room.leave(consented);
        },

        /**
         * Get room ID
         */
        getRoomId: function(roomId) {
            const room = this.rooms[roomId];
            return room ? room.id : "";
        },

        /**
         * Get session ID
         */
        getSessionId: function(roomId) {
            const room = this.rooms[roomId];
            return room ? room.sessionId : "";
        },

        /**
         * Get room name
         */
        getRoomName: function(roomId) {
            const room = this.rooms[roomId];
            return room ? room.name : "";
        },

        /**
         * Get room state as JSON
         */
        getState: function(roomId) {
            const room = this.rooms[roomId];
            if (!room || !room.state) return "{}";
            return JSON.stringify(room.state.toJSON ? room.state.toJSON() : room.state);
        },

        /**
         * Check if room connection is open
         */
        hasJoined: function(roomId) {
            const room = this.rooms[roomId];
            return room ? room.connection.isOpen : false;
        },

        /**
         * Get reconnection token
         */
        getReconnectionToken: function(roomId) {
            const room = this.rooms[roomId];
            return room ? (room.reconnectionToken || "") : "";
        },

        /**
         * Dispose of a client
         */
        disposeClient: function(clientId) {
            delete this.clients[clientId];
        },

        /**
         * Dispose of a room
         */
        disposeRoom: function(roomId) {
            delete this.rooms[roomId];
            delete this._callbacks[roomId];
        },

        /**
         * Listen to state property changes (0.17 API)
         * @param {number} roomId 
         * @param {string} path - Property path on state
         * @param {function} callback - Called with resultId
         */
        listen: function(roomId, path, callback) {
            const self = this;
            const room = this.rooms[roomId];
            const roomCallbacks = this._callbacks[roomId];
            if (!room || !room.state || !roomCallbacks || !roomCallbacks.callbacks) return -1;

            const listenerId = this._nextId++;
            
            try {
                roomCallbacks.callbacks.listen(path, function(current, previous) {
                    if (callback) {
                        const resultId = self._nextId++;
                        self._pendingResults[resultId] = JSON.stringify({current: current, previous: previous});
                        callback(resultId);
                    }
                });
            } catch (e) {
                console.warn("ColyseusGodot: Failed to listen to path:", path, e);
                return -1;
            }
            
            return listenerId;
        },

        /**
         * Listen to entity property changes (0.17 API)
         * Used to listen to properties on entities inside collections
         * @param {number} roomId 
         * @param {number} entityRefId - The entity's refId (returned in onAdd)
         * @param {string} property - Property name on the entity
         * @param {function} callback - Called with resultId
         */
        listenEntity: function(roomId, entityRefId, property, callback) {
            const self = this;
            const roomCallbacks = this._callbacks[roomId];
            if (!roomCallbacks || !roomCallbacks.callbacks) return -1;

            const entity = roomCallbacks.entities[entityRefId];
            if (!entity) {
                console.warn("ColyseusGodot: Entity not found with refId:", entityRefId);
                return -1;
            }

            const listenerId = this._nextId++;
            
            try {
                roomCallbacks.callbacks.listen(entity, property, function(current, previous) {
                    if (callback) {
                        const resultId = self._nextId++;
                        self._pendingResults[resultId] = JSON.stringify({current: current, previous: previous});
                        callback(resultId);
                    }
                });
            } catch (e) {
                console.warn("ColyseusGodot: Failed to listen to entity property:", property, e);
                return -1;
            }
            
            return listenerId;
        },

        /**
         * Listen to collection additions (Map/Array) (0.17 API)
         * @param {number} roomId 
         * @param {string} path - Collection path
         * @param {function} callback - Called with resultId
         */
        onAdd: function(roomId, path, callback) {
            const self = this;
            const room = this.rooms[roomId];
            const roomCallbacks = this._callbacks[roomId];
            if (!room || !room.state || !roomCallbacks || !roomCallbacks.callbacks) return -1;

            const listenerId = this._nextId++;
            
            try {
                roomCallbacks.callbacks.onAdd(path, function(item, key) {
                    if (callback) {
                        const refId = item.$changes ? item.$changes.refId : self._nextId++;
                        
                        // Store entity reference for later use with listenEntity
                        if (item && typeof item === 'object') {
                            roomCallbacks.entities[refId] = item;
                        }
                        
                        const resultId = self._nextId++;
                        self._pendingResults[resultId] = JSON.stringify({
                            item: item.toJSON ? item.toJSON() : item,
                            key: String(key),
                            refId: refId
                        });
                        callback(resultId);
                    }
                });
            } catch (e) {
                console.warn("ColyseusGodot: Failed to set onAdd for path:", path, e);
                return -1;
            }
            
            return listenerId;
        },

        /**
         * Listen to collection removals (Map/Array) (0.17 API)
         * @param {number} roomId 
         * @param {string} path - Collection path
         * @param {function} callback - Called with resultId
         */
        onRemove: function(roomId, path, callback) {
            const self = this;
            const room = this.rooms[roomId];
            const roomCallbacks = this._callbacks[roomId];
            if (!room || !room.state || !roomCallbacks || !roomCallbacks.callbacks) return -1;

            const listenerId = this._nextId++;
            
            try {
                roomCallbacks.callbacks.onRemove(path, function(item, key) {
                    if (callback) {
                        const refId = item.$changes ? item.$changes.refId : -1;
                        
                        // Clean up entity reference
                        if (refId !== -1 && roomCallbacks.entities[refId]) {
                            delete roomCallbacks.entities[refId];
                        }
                        
                        const resultId = self._nextId++;
                        self._pendingResults[resultId] = JSON.stringify({
                            item: item.toJSON ? item.toJSON() : item,
                            key: String(key),
                            refId: refId
                        });
                        callback(resultId);
                    }
                });
            } catch (e) {
                console.warn("ColyseusGodot: Failed to set onRemove for path:", path, e);
                return -1;
            }
            
            return listenerId;
        },

        /**
         * Listen to entity collection additions (0.17 API)
         * Used to listen to onAdd on collections inside entities
         * @param {number} roomId 
         * @param {number} entityRefId - The entity's refId (returned in onAdd)
         * @param {string} path - Collection property name on the entity
         * @param {function} callback - Called with resultId
         */
        onAddEntity: function(roomId, entityRefId, path, callback) {
            const self = this;
            const roomCallbacks = this._callbacks[roomId];
            if (!roomCallbacks || !roomCallbacks.callbacks) return -1;

            const entity = roomCallbacks.entities[entityRefId];
            if (!entity) {
                console.warn("ColyseusGodot: Entity not found with refId:", entityRefId);
                return -1;
            }

            const listenerId = this._nextId++;
            
            try {
                roomCallbacks.callbacks.onAdd(entity, path, function(item, key) {
                    if (callback) {
                        const refId = item.$changes ? item.$changes.refId : self._nextId++;
                        
                        // Store entity reference for later use with listenEntity
                        if (item && typeof item === 'object') {
                            roomCallbacks.entities[refId] = item;
                        }
                        
                        const resultId = self._nextId++;
                        self._pendingResults[resultId] = JSON.stringify({
                            item: item.toJSON ? item.toJSON() : item,
                            key: String(key),
                            refId: refId
                        });
                        callback(resultId);
                    }
                });
            } catch (e) {
                console.warn("ColyseusGodot: Failed to set onAdd for entity path:", path, e);
                return -1;
            }
            
            return listenerId;
        },

        /**
         * Listen to entity collection removals (0.17 API)
         * Used to listen to onRemove on collections inside entities
         * @param {number} roomId 
         * @param {number} entityRefId - The entity's refId (returned in onAdd)
         * @param {string} path - Collection property name on the entity
         * @param {function} callback - Called with resultId
         */
        onRemoveEntity: function(roomId, entityRefId, path, callback) {
            const self = this;
            const roomCallbacks = this._callbacks[roomId];
            if (!roomCallbacks || !roomCallbacks.callbacks) return -1;

            const entity = roomCallbacks.entities[entityRefId];
            if (!entity) {
                console.warn("ColyseusGodot: Entity not found with refId:", entityRefId);
                return -1;
            }

            const listenerId = this._nextId++;
            
            try {
                roomCallbacks.callbacks.onRemove(entity, path, function(item, key) {
                    if (callback) {
                        const refId = item.$changes ? item.$changes.refId : -1;
                        
                        // Clean up entity reference
                        if (refId !== -1 && roomCallbacks.entities[refId]) {
                            delete roomCallbacks.entities[refId];
                        }
                        
                        const resultId = self._nextId++;
                        self._pendingResults[resultId] = JSON.stringify({
                            item: item.toJSON ? item.toJSON() : item,
                            key: String(key),
                            refId: refId
                        });
                        callback(resultId);
                    }
                });
            } catch (e) {
                console.warn("ColyseusGodot: Failed to set onRemove for entity path:", path, e);
                return -1;
            }
            
            return listenerId;
        },

        /**
         * Setup raw changes callback for efficient schema synchronization
         * This replaces the per-event JSON serialization with a batch approach
         * @param {number} roomId 
         * @param {function} callback - Called with resultId containing serialized changes array
         */
        setupRawChanges: function(roomId, callback) {
            const self = this;
            const room = this.rooms[roomId];
            if (!room) {
                console.warn("ColyseusGodot: Room not found for setupRawChanges:", roomId);
                return;
            }

            const decoder = room.serializer.decoder;
            if (!decoder) {
                console.warn("ColyseusGodot: Decoder not available for room:", roomId);
                return;
            }

            // Helper to serialize a value safely
            // Returns [type, value_or_refId]
            function serializeValue(val) {
                if (val === undefined) {
                    return [VALUE_UNDEFINED, null];
                }
                if (val === null) {
                    return [VALUE_PRIMITIVE, null];
                }
                
                // Check for Schema instance
                if (isSchema(val)) {
                    return [VALUE_REF, val['~refId']];
                }
                
                // Check for Collection (Map/Array/Set) - has ~refId
                if (val && typeof val === 'object' && val['~refId'] !== undefined) {
                    return [VALUE_REF, val['~refId']];
                }
                
                // True primitives only
                const valType = typeof val;
                if (valType === 'number' || valType === 'string' || valType === 'boolean') {
                    return [VALUE_PRIMITIVE, val];
                }
                
                // Unknown complex type - log warning, don't serialize
                console.warn('ColyseusGodot: Unhandled value type in raw change:', val);
                return [VALUE_UNKNOWN, null];
            }

            Colyseus.Callbacks.getRawChanges(decoder, function(allChanges) {
                console.log("ColyseusGodot: getRawChanges triggered with", allChanges.length, "changes");
                
                const serialized = [];
                for (let i = 0; i < allChanges.length; i++) {
                    const change = allChanges[i];
                    const valInfo = serializeValue(change.value);
                    const prevInfo = serializeValue(change.previousValue);
                    
                    console.log("ColyseusGodot: Change", i, "- refId:", change.refId, "op:", change.op, "field:", change.field, "dynamicIndex:", change.dynamicIndex, "isSchema:", isSchema(change.ref), "valType:", valInfo[0], "valData:", valInfo[1]);
                    
                    // Compact array format: [refId, op, field, dynamicIndex, isSchema, valType, valData, prevType, prevData]
                    serialized.push([
                        change.refId,
                        change.op,
                        change.field,
                        change.dynamicIndex !== undefined ? change.dynamicIndex : null,
                        isSchema(change.ref) ? 1 : 0,
                        valInfo[0],
                        valInfo[1],
                        prevInfo[0],
                        prevInfo[1]
                    ]);
                }
                
                if (callback && serialized.length > 0) {
                    const resultId = self._nextId++;
                    self._pendingResults[resultId] = JSON.stringify(serialized);
                    console.log("ColyseusGodot: Calling GDScript callback with resultId:", resultId, "serialized:", serialized.length, "changes");
                    callback(resultId);
                } else {
                    console.log("ColyseusGodot: No changes to send or no callback");
                }
            });
            
            console.log("ColyseusGodot: Raw changes callback registered for room", roomId);
        }
    };

    console.log("ColyseusGodot bridge initialized");
})();
