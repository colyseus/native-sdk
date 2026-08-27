import CColyseus
import Foundation

public extension Colyseus {
    /// Reacts to what the decoder changed.
    ///
    /// ```swift
    /// let callbacks = Colyseus.Callbacks.get(room)
    /// callbacks.onAdd(state.players) { sessionId, player in ... }
    /// callbacks.listen(state, "phase", as: String.self) { phase, _ in ... }
    /// ```
    ///
    /// Handlers fire inside ``Colyseus/pump()``, on the same thread and in the
    /// same frame as the patch that caused them.
    final class Callbacks: @unchecked Sendable {
        private let raw: OpaquePointer?
        private let registrations = Guarded<[Int32: Registration]>([:])

        private struct Registration {
            let handle: colyseus_callback_handle_t
            let release: () -> Void
        }

        init(_ raw: OpaquePointer?) {
            self.raw = raw
        }

        deinit { invalidate() }

        /// Drop every registration without telling the C layer.
        ///
        /// Called by the room on its way out: by then the layer it registered
        /// against has been freed, and unregistering would read it.
        func invalidate() {
            isValid.current = false
            registrations.withLock { entries in
                for entry in entries.values { entry.release() }
                entries.removeAll()
            }
        }

        private let isValid = Guarded(true)

        /// The room's own callback layer. A room has exactly one, so several
        /// callers — and a ``Colyseus/Predict`` — share it.
        public static func get<State: SchemaRef>(_ room: Room<State>) -> Callbacks {
            room.callbacks
        }

        // MARK: - Fields

        /// Watch one field of one instance.
        ///
        /// With `immediate` (the default) the handler also fires once with
        /// whatever the field already holds, so a UI does not have to draw an
        /// empty first frame.
        ///
        /// ```swift
        /// callbacks.listen(state, "phase", as: String.self) { phase, previous in ... }
        /// callbacks.listen(player, "x", as: Double.self) { x, _ in ... }
        /// ```
        @discardableResult
        public func listen<Value: SchemaValue>(
            _ owner: SchemaRef,
            _ field: String,
            as _: Value.Type = Value.self,
            immediate: Bool = true,
            _ handler: @escaping @Sendable (Value?, Value?) -> Void
        ) -> Subscription {
            let primitive = owner.view.type(of: field)
            let box = PropertyHandler { value, previous in
                handler(
                    value.flatMap { Value._fromSchemaSlot($0, primitive: primitive) },
                    previous.flatMap { Value._fromSchemaSlot($0, primitive: primitive) }
                )
            }

            return register(box) { raw, pointer in
                field.withCString { fieldPointer in
                    colyseus_callbacks_listen(raw, owner.handle, fieldPointer, { value, previous, userdata in
                        borrowObject(userdata, as: PropertyHandler.self)?.body(value, previous)
                    }, pointer, immediate)
                }
            }
        }

        /// Any field of this instance changed. Fires once per patch that
        /// touched it, not once per field.
        @discardableResult
        public func onChange(
            _ instance: SchemaRef,
            _ handler: @escaping @Sendable () -> Void
        ) -> Subscription {
            let box = SignalHandler(handler)
            return register(box) { raw, pointer in
                colyseus_callbacks_on_change_instance(raw, instance.handle, { userdata in
                    borrowObject(userdata, as: SignalHandler.self)?.body()
                }, pointer)
            }
        }

        // MARK: - Maps

        @discardableResult
        public func onAdd<Element: SchemaValue>(
            _ collection: MapSchema<Element>,
            immediate: Bool = true,
            _ handler: @escaping @Sendable (String, Element) -> Void
        ) -> Subscription {
            mapCallback(collection, handler) { raw, owner, field, pointer, trampoline in
                colyseus_callbacks_on_add(raw, owner, field, trampoline, pointer, immediate)
            }
        }

        @discardableResult
        public func onRemove<Element: SchemaValue>(
            _ collection: MapSchema<Element>,
            _ handler: @escaping @Sendable (String, Element) -> Void
        ) -> Subscription {
            mapCallback(collection, handler) { raw, owner, field, pointer, trampoline in
                colyseus_callbacks_on_remove(raw, owner, field, trampoline, pointer)
            }
        }

        // MARK: - Arrays

        @discardableResult
        public func onAdd<Element: SchemaValue>(
            _ collection: ArraySchema<Element>,
            immediate: Bool = true,
            _ handler: @escaping @Sendable (Int, Element) -> Void
        ) -> Subscription {
            arrayCallback(collection, handler) { raw, owner, field, pointer, trampoline in
                colyseus_callbacks_on_add(raw, owner, field, trampoline, pointer, immediate)
            }
        }

        @discardableResult
        public func onRemove<Element: SchemaValue>(
            _ collection: ArraySchema<Element>,
            _ handler: @escaping @Sendable (Int, Element) -> Void
        ) -> Subscription {
            arrayCallback(collection, handler) { raw, owner, field, pointer, trampoline in
                colyseus_callbacks_on_remove(raw, owner, field, trampoline, pointer)
            }
        }

        // MARK: - Plumbing

        /// Registration goes through the OWNER instance and the field name, not
        /// through the collection pointer. A server that replaces the whole
        /// collection leaves a pointer-keyed registration watching something
        /// nobody reads any more.
        private func mapCallback<Element: SchemaValue>(
            _ collection: MapSchema<Element>,
            _ handler: @escaping @Sendable (String, Element) -> Void,
            _ install: (OpaquePointer, UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafeMutableRawPointer, colyseus_item_callback_fn) -> colyseus_callback_handle_t
        ) -> Subscription {
            let primitive = elementType(of: collection.owner, field: collection.field)
            let box = ItemHandler { value, key in
                guard let value, let key,
                      let element = Element._fromSchemaSlot(value, primitive: primitive)
                else { return }
                handler(String(cString: key.assumingMemoryBound(to: CChar.self)), element)
            }

            return register(box) { raw, pointer in
                collection.field.withCString { fieldPointer in
                    install(raw, collection.owner.handle, fieldPointer, pointer, { value, key, userdata in
                        borrowObject(userdata, as: ItemHandler.self)?.body(value, key)
                    })
                }
            }
        }

        private func arrayCallback<Element: SchemaValue>(
            _ collection: ArraySchema<Element>,
            _ handler: @escaping @Sendable (Int, Element) -> Void,
            _ install: (OpaquePointer, UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafeMutableRawPointer, colyseus_item_callback_fn) -> colyseus_callback_handle_t
        ) -> Subscription {
            let primitive = elementType(of: collection.owner, field: collection.field)
            let box = ItemHandler { value, key in
                guard let value, let key,
                      let element = Element._fromSchemaSlot(value, primitive: primitive)
                else { return }
                handler(Int(key.assumingMemoryBound(to: Int32.self).pointee), element)
            }

            return register(box) { raw, pointer in
                collection.field.withCString { fieldPointer in
                    install(raw, collection.owner.handle, fieldPointer, pointer, { value, key, userdata in
                        borrowObject(userdata, as: ItemHandler.self)?.body(value, key)
                    })
                }
            }
        }

        /// A collection of schemas hands out instances; a collection of
        /// primitives hands out raw storage, and then the declared type is what
        /// says how wide it is.
        private func elementType(of owner: SchemaRef, field: String) -> SchemaFieldType? {
            guard let child = owner.view.child(field) else { return nil }

            switch owner.view.type(of: field) {
            case .map:
                let map = child.assumingMemoryBound(to: colyseus_map_schema_t.self)
                guard !map.pointee.has_schema_child else { return nil }
                return String(nullableCString: map.pointee.child_primitive_type)
                    .flatMap { SchemaFieldType(colyseus_field_type_from_string($0)) }
            case .array:
                let array = child.assumingMemoryBound(to: colyseus_array_schema_t.self)
                guard !array.pointee.has_schema_child else { return nil }
                return String(nullableCString: array.pointee.child_primitive_type)
                    .flatMap { SchemaFieldType(colyseus_field_type_from_string($0)) }
            default:
                return nil
            }
        }

        private func register<Box: AnyObject>(
            _ box: Box,
            _ install: (OpaquePointer, UnsafeMutableRawPointer) -> colyseus_callback_handle_t
        ) -> Subscription {
            guard let raw else { return Subscription {} }

            let pointer = retainedPointer(box)
            let handle = install(raw, pointer)

            guard handle != COLYSEUS_INVALID_CALLBACK_HANDLE else {
                releasePointer(pointer, as: Box.self)
                return Subscription {}
            }

            registrations.withLock { entries in
                entries[handle] = Registration(handle: handle) {
                    releasePointer(pointer, as: Box.self)
                }
            }

            return Subscription { [weak self] in self?.cancel(handle) }
        }

        private func cancel(_ handle: colyseus_callback_handle_t) {
            let entry = registrations.withLock { $0.removeValue(forKey: handle) }
            guard let entry else { return }
            // A subscription cancelled after the room closed has nothing left
            // to unregister from.
            if let raw, isValid.current {
                colyseus_callbacks_remove(raw, entry.handle)
            }
            entry.release()
        }
    }
}

// The C callbacks are function pointers, so each closure has to live in an
// object the userdata pointer can reach.

private final class PropertyHandler: @unchecked Sendable {
    let body: (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    init(_ body: @escaping (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void) { self.body = body }
}

private final class ItemHandler: @unchecked Sendable {
    let body: (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    init(_ body: @escaping (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void) { self.body = body }
}

private final class SignalHandler: @unchecked Sendable {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}
