import { Room, Client } from "@colyseus/core";
import { schema, t } from "@colyseus/schema";

/**
 * Field kinds TestRoom doesn't carry, for binding decode tests: a quantized
 * float, a plain number, and primitive collections.
 */
const FixtureState = schema({
  yaw: t.quantized({ min: 0, max: Math.PI * 2, mode: "wrap" }),
  speed: t.number(),
  bytes: t.array("uint8"),
  scores: t.map("number"),
}, "FixtureState");

export class BindingFixtureRoom extends Room {
  state = new FixtureState();

  messages = {
    set: (_client: Client, message: { yaw?: number, speed?: number }) => {
      if (typeof message?.yaw === "number") this.state.yaw = message.yaw;
      if (typeof message?.speed === "number") this.state.speed = message.speed;
    },
    push_byte: (_client: Client, value: number) => { this.state.bytes.push(value); },
    shift_byte: (_client: Client) => { this.state.bytes.shift(); },
    set_score: (_client: Client, message: { key: string, value: number }) => {
      this.state.scores.set(message.key, message.value);
    },
    delete_score: (_client: Client, key: string) => { this.state.scores.delete(key); },
  };

  onCreate(options?: { private?: boolean }) {
    // suites share one server: a private room keeps each test's state to itself
    if (options?.private) this.setPrivate();
    this.state.yaw = 1.5;
    this.state.speed = 2.5;
    this.state.bytes.push(7, 8, 9);
    this.state.scores.set("a", 1.5);
  }
}
