import Colyseus

// The example server's TestRoom state, written the way
// `schema-codegen --swift` will emit it. Kept by hand until the generator
// lands, and then this file becomes its reference output.

public final class Item: SchemaRef {
    public var name: String { view.string("name") ?? "" }
    public var value: Double { view["value"] }
}

public final class Player: SchemaRef {
    public var x: Double { view["x"] }
    public var y: Double { view["y"] }
    public var isBot: Bool { view.bool("isBot") }
    public var disconnected: Bool { view.bool("disconnected") }
    public var items: ArraySchema<Item> { arrayOf("items") }
}

public final class TestRoomState: SchemaRef {
    public var players: MapSchema<Player> { mapOf("players") }
    public var host: Player? { refOf("host") }
    public var currentTurn: String { view.string("currentTurn") ?? "" }
}
