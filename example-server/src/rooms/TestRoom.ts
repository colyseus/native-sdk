import { type Client, generateId, Room } from "@colyseus/core";
import { MapSchema, Schema, type } from "@colyseus/schema";

class Item extends Schema {
  @type("string") name?: string;
  @type("number") value?: number;
}

class Player extends Schema {
  @type("number") x: number = 0;
  @type("number") y: number = 0;
  @type("boolean") isBot?: boolean;
  @type("boolean") disconnected?: boolean;
  @type([Item]) items: Item[] = [];
}

class TestRoomState extends Schema {
  @type({ map: Player }) players = new MapSchema<Player>();
  @type(Player) host?: Player;
  @type("string") currentTurn?: string;
}

/**
 * Room definition
 * ----------------
 */
export class TestRoom extends Room {
  state = new TestRoomState();

  messages = {
    move: (client: Client, message: { x: number, y: number }) => {
      const player = this.state.players.get(client.sessionId);
      if (!player) return;

      player.x = message.x;
      player.y = message.y;
    },
    add_item: (client: Client, message: { name: string }) => {
      const player = this.state.players.get(client.sessionId);
      if (!player) return;

      player.items.push(new Item().assign({ name: message.name }));
    },
    remove_item: (client: Client) => {
      const player = this.state.players.get(client.sessionId);
      if (!player) return;
      if (player.items.length === 0) return;

      const randomIndex = Math.floor(Math.random() * player.items.length);
      player.items.splice(randomIndex, 1);
    },
    add_bot: (client: Client) => {
      const botId = generateId();
      this.state.players.set(botId, new Player().assign({
        isBot: true,
        x: Math.random() * 800,
        y: Math.random() * 600,
      }));
    },
    remove_bot: (client: Client, message: { name: string }) => {
      const bot = this.state.players.entries().find(([_, player]) => player.isBot)
      if (bot) {
        this.state.players.delete(bot[0]);
      }
    },
  }

  onCreate() {
    // broadcast "weather" event every 4 seconds
    this.clock.setInterval(() => {
      const weather = ["sunny", "cloudy", "rainy", "snowy"];
      this.broadcast("weather", { weather: weather[Math.floor(Math.random() * weather.length)] });
    }, 4000);
  }

  onJoin(client: Client) {
    const player = new Player();
    player.items.push(new Item().assign({ name: "sword" }));

    if (!this.state.host) {
      this.state.host = player;
      this.state.currentTurn = client.sessionId;
    }

    this.state.players.set(client.sessionId, player);

    // advance turn every 2 seconds
    this.clock.setInterval(() => {
      const sessionIds = Array.from(this.state.players.keys());
      const nextSessionId = sessionIds.find(sessionId => sessionId === this.state.currentTurn);
      this.state.currentTurn = nextSessionId;
    }, 2000);

    // move bots
    this.setSimulationInterval(() => {
      this.state.players.forEach(player => {
        if (player.isBot) {
          player.x += Math.random() * 10 - 5;
          player.y += Math.random() * 10 - 5;
        }
      });
    });
  }

  async onDrop(client: Client) {
    const player = this.state.players.get(client.sessionId);
    if (player) {
      player.disconnected = true;
    }
    await this.allowReconnection(client, 10);
  }

  onReconnect(client: Client) {
    const player = this.state.players.get(client.sessionId);
    if (player) {
      player.disconnected = false;
    }
  }

  onLeave(client: Client, code?: number) {
    const player = this.state.players.get(client.sessionId);
    if (player) {
      this.state.players.delete(client.sessionId);

      // if the player is the host, assign a new host
      if (this.state.host === player && this.state.players.size > 0) {
        this.state.host = this.state.players.values().next().value;
      }
    }
  }
}