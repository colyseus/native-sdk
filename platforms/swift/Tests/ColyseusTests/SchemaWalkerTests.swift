import XCTest
@testable import Colyseus
import CColyseus

/// Exercises `SchemaWalker` against the native dynamic-schema C API.
/// This validates Swift↔C struct layout and conversion — not full parity with
/// the JavaScript `@colyseus/schema` encoder/decoder (that would need fixture bytes + room decode tests).
final class SchemaWalkerTests: XCTestCase {

    // MARK: - Helpers

    private func addDynamicField(
        _ vtable: UnsafeMutablePointer<colyseus_dynamic_vtable_t>,
        index: Int32,
        name: String,
        type: colyseus_field_type_t,
        typeStr: String
    ) {
        name.withCString { nameC in
            typeStr.withCString { tsC in
                guard let field = colyseus_dynamic_field_create(index, nameC, type, tsC) else {
                    XCTFail("colyseus_dynamic_field_create failed")
                    return
                }
                colyseus_dynamic_vtable_add_field(vtable, field)
            }
        }
    }

    private func setValue(
        _ schema: UnsafeMutablePointer<colyseus_dynamic_schema_t>,
        index: Int32,
        name: String,
        kind: colyseus_field_type_t,
        _ configure: (UnsafeMutablePointer<colyseus_dynamic_value_t>) -> Void
    ) {
        guard let value = colyseus_dynamic_value_create(kind) else {
            XCTFail("colyseus_dynamic_value_create failed")
            return
        }
        configure(value)
        name.withCString { nameC in
            colyseus_dynamic_schema_set(schema, index, nameC, value)
        }
    }

    // MARK: - Tests

    func testWalkFlatPrimitives() {
        guard let vtable = colyseus_dynamic_vtable_create("TestFlat") else {
            return XCTFail("vtable create")
        }
        defer { colyseus_dynamic_vtable_free(vtable) }

        addDynamicField(vtable, index: 0, name: "title", type: COLYSEUS_FIELD_STRING, typeStr: "string")
        addDynamicField(vtable, index: 1, name: "score", type: COLYSEUS_FIELD_NUMBER, typeStr: "number")
        addDynamicField(vtable, index: 2, name: "alive", type: COLYSEUS_FIELD_BOOLEAN, typeStr: "boolean")
        addDynamicField(vtable, index: 3, name: "ticks", type: COLYSEUS_FIELD_INT64, typeStr: "int64")
        addDynamicField(vtable, index: 4, name: "token", type: COLYSEUS_FIELD_UINT64, typeStr: "uint64")

        guard let schema = colyseus_dynamic_schema_create(vtable) else {
            return XCTFail("schema create")
        }
        defer { colyseus_dynamic_schema_free(schema) }

        setValue(schema, index: 0, name: "title", kind: COLYSEUS_FIELD_STRING) { v in
            "hello".withCString { colyseus_dynamic_value_set_string(v, $0) }
        }
        setValue(schema, index: 1, name: "score", kind: COLYSEUS_FIELD_NUMBER) { v in
            colyseus_dynamic_value_set_number(v, 42.5)
        }
        setValue(schema, index: 2, name: "alive", kind: COLYSEUS_FIELD_BOOLEAN) { v in
            colyseus_dynamic_value_set_boolean(v, true)
        }
        setValue(schema, index: 3, name: "ticks", kind: COLYSEUS_FIELD_INT64) { v in
            colyseus_dynamic_value_set_int64(v, -100)
        }
        setValue(schema, index: 4, name: "token", kind: COLYSEUS_FIELD_UINT64) { v in
            colyseus_dynamic_value_set_uint64(v, 9_000_000_000_000_000_001)
        }

        let state = SchemaWalker.walk(UnsafeMutableRawPointer(schema))

        XCTAssertEqual(state.count, 5)
        XCTAssertEqual(state["title"] as? String, "hello")
        guard let score = state["score"] as? Double else { return XCTFail("score type") }
        XCTAssertEqual(score, 42.5, accuracy: 1e-9)
        XCTAssertEqual(state["alive"] as? Bool, true)
        XCTAssertEqual(state["ticks"] as? Int64, -100)
        XCTAssertEqual(state["token"] as? UInt64, 9_000_000_000_000_000_001)
    }

    func testWalkFloat32AndFloat64Kinds() {
        guard let vtable = colyseus_dynamic_vtable_create("TestFloats") else {
            return XCTFail("vtable create")
        }
        defer { colyseus_dynamic_vtable_free(vtable) }

        addDynamicField(vtable, index: 0, name: "f32", type: COLYSEUS_FIELD_FLOAT32, typeStr: "float32")
        addDynamicField(vtable, index: 1, name: "f64", type: COLYSEUS_FIELD_FLOAT64, typeStr: "float64")

        guard let schema = colyseus_dynamic_schema_create(vtable) else {
            return XCTFail("schema create")
        }
        defer { colyseus_dynamic_schema_free(schema) }

        setValue(schema, index: 0, name: "f32", kind: COLYSEUS_FIELD_FLOAT32) { v in
            colyseus_dynamic_value_set_float32(v, 1.25)
        }
        setValue(schema, index: 1, name: "f64", kind: COLYSEUS_FIELD_NUMBER) { v in
            colyseus_dynamic_value_set_number(v, 3.5)
            v.pointee.type = COLYSEUS_FIELD_FLOAT64
        }

        let state = SchemaWalker.walk(UnsafeMutableRawPointer(schema))

        guard let f32 = state["f32"] as? Double else { return XCTFail("f32 type") }
        guard let f64 = state["f64"] as? Double else { return XCTFail("f64 type") }
        XCTAssertEqual(f32, 1.25, accuracy: 1e-6)
        XCTAssertEqual(f64, 3.5, accuracy: 1e-9)
    }

    func testWalkNestedRef() {
        guard let childVt = colyseus_dynamic_vtable_create("Child") else {
            return XCTFail("child vtable")
        }
        defer { colyseus_dynamic_vtable_free(childVt) }
        addDynamicField(childVt, index: 0, name: "n", type: COLYSEUS_FIELD_STRING, typeStr: "string")

        guard let parentVt = colyseus_dynamic_vtable_create("Parent") else {
            return XCTFail("parent vtable")
        }
        defer { colyseus_dynamic_vtable_free(parentVt) }
        addDynamicField(parentVt, index: 0, name: "label", type: COLYSEUS_FIELD_STRING, typeStr: "string")
        addDynamicField(parentVt, index: 1, name: "child", type: COLYSEUS_FIELD_REF, typeStr: "ref")
        colyseus_dynamic_vtable_set_child(parentVt, 1, childVt)

        guard let childSchema = colyseus_dynamic_schema_create(childVt) else {
            return XCTFail("child schema")
        }
        setValue(childSchema, index: 0, name: "n", kind: COLYSEUS_FIELD_STRING) { v in
            "inner".withCString { colyseus_dynamic_value_set_string(v, $0) }
        }

        guard let parentSchema = colyseus_dynamic_schema_create(parentVt) else {
            colyseus_dynamic_schema_free(childSchema)
            return XCTFail("parent schema")
        }

        setValue(parentSchema, index: 0, name: "label", kind: COLYSEUS_FIELD_STRING) { v in
            "root".withCString { colyseus_dynamic_value_set_string(v, $0) }
        }
        guard let refVal = colyseus_dynamic_value_create(COLYSEUS_FIELD_REF) else {
            colyseus_dynamic_schema_free(parentSchema)
            colyseus_dynamic_schema_free(childSchema)
            return XCTFail("ref value")
        }
        colyseus_dynamic_value_set_ref(refVal, childSchema)
        "child".withCString { colyseus_dynamic_schema_set(parentSchema, 1, $0, refVal) }

        let state = SchemaWalker.walk(UnsafeMutableRawPointer(parentSchema))

        colyseus_dynamic_schema_free(parentSchema)
        colyseus_dynamic_schema_free(childSchema)

        XCTAssertEqual(state["label"] as? String, "root")
        let nested = state["child"] as? SchemaState
        XCTAssertNotNil(nested)
        XCTAssertEqual(nested?["n"] as? String, "inner")
    }
}
