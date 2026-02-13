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
