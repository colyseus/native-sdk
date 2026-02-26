import { Room, Client } from "@colyseus/core";
import { Schema, type } from "@colyseus/schema";

export class MyRoomState extends Schema {
  @type("string") mySynchronizedProperty: string = "Hello world";
}

export class MyRoom extends Room {
  maxClients = 4;
  state = new MyRoomState();

  messages = {
    test: (client: Client, message: string) => {
      console.log("Received 'test' message.", { sessionId: client.sessionId, message });
    },
    test_message_types: (client: Client, message: any) => {
      client.send("message_types", {
        // Strings
        string: "hello world",
        emptyString: "",
        unicodeString: "こんにちは 🎮 émojis",

        // Numbers
        positiveInt: 42,
        negativeInt: -123,
        zero: 0,
        float: 3.14159,
        negativeFloat: -2.71828,
        largeInt: 2147483647,
        smallInt: -2147483648,
        infinity: Infinity,
        negativeInfinity: -Infinity,
        nan: NaN,

        // Booleans
        boolTrue: true,
        boolFalse: false,

        // Null and Undefined
        nullValue: null,
        undefinedValue: undefined,

        // Date
        date: new Date(),
        specificDate: new Date("2024-06-15T10:30:00Z"),

        // Arrays
        emptyArray: [],
        numberArray: [1, 2, 3, 4, 5],
        stringArray: ["a", "b", "c"],
        mixedArray: [1, "two", true, null, undefined, { nested: "object" }],

        // Nested objects
        nestedObject: {
          level1: {
            level2: {
              level3: {
                deep: "value"
              }
            }
          }
        },

        // Empty object
        emptyObject: {},

        // Binary data
        uint8Array: new Uint8Array([0, 1, 2, 255, 128, 64]),
        buffer: Buffer.from([10, 20, 30, 40, 50]),

        // Special cases
        arrayWithHoles: [1, , , 4], // sparse array
      })
    },
    _: (client: Client, type: string, message: any) => {
      console.log("Received unknown message.", { sessionId: client.sessionId, type, message });
    }
  }

  onJoin (client: Client, options: any) {
    console.log(client.sessionId, "joined!");
  }

  onLeave (client: Client, code: number) {
    console.log(client.sessionId, "left!");
  }

  onDispose() {
    console.log("room", this.roomId, "disposing...");
  }

}
