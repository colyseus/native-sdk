import { type Client, Room } from "@colyseus/core";
import { schema, StateView } from "@colyseus/schema";

/**
 * Minimal room to test StateView with view:true arrays.
 * Uses schema() function (not decorators) — native clients
 * discover the structure via reflection (dynamic schemas).
 */

const Card = schema({
  id: "string",
  color: "string",
  value: "number",
});

const Player = schema({
  sessionId: "string",
  hand: { array: Card, view: true },  // only visible to owning client
  handCount: "number",                 // visible to all
});

const ViewTestState = schema({
  players: { map: Player },
  discardPile: { array: Card },  // visible to all (no view)
  round: "number",
});

type PlayerInstance = InstanceType<typeof Player>;
type CardInstance = InstanceType<typeof Card>;

let cardUid = 0;

function makeCard(color: string, value: number): CardInstance {
  const c = new Card();
  c.id = `${color}_${value}_${cardUid++}`;
  c.color = color;
  c.value = value;
  return c;
}

export class ViewTestRoom extends Room {
  state = new ViewTestState();

  private getPlayer(client: Client): PlayerInstance | undefined {
    return this.state.players.get(client.sessionId);
  }

  private pushCardToHand(player: PlayerInstance, card: CardInstance, client?: Client) {
    player.hand.push(card);
    player.handCount = player.hand.length;

    // Register new card with the client's StateView
    if (!client) {
      client = this.clients.find(c => c.sessionId === player.sessionId);
    }
    if (client?.view) {
      client.view.add(card);
    }
  }

  messages = {
    /**
     * Splice all hand cards and push new ones in the same tick.
     * This is the exact pattern that triggers the bug:
     * view:true array splice+push without explicit view.remove().
     */
    reset_hand: (client: Client, message: { newCount: number }) => {
      const player = this.getPlayer(client);
      if (!player) return;

      const newCount = message.newCount ?? 3;

      // Splice all old cards (same tick as push below)
      player.hand.splice(0, player.hand.length);
      player.handCount = 0;

      // Push new cards
      const colors = ["red", "blue", "green", "yellow"];
      for (let i = 0; i < newCount; i++) {
        this.pushCardToHand(player, makeCard(colors[i % 4], i + 100), client);
      }

      this.state.round++;
    },

    /**
     * Splice all discard cards and push new ones (non-view array, for comparison).
     */
    reset_discard: (client: Client, message: { newCount: number }) => {
      const newCount = message.newCount ?? 2;

      this.state.discardPile.splice(0, this.state.discardPile.length);

      for (let i = 0; i < newCount; i++) {
        this.state.discardPile.push(makeCard("discard", i + 200));
      }

      this.state.round++;
    },

    /**
     * Add a single card to hand.
     */
    add_card: (client: Client) => {
      const player = this.getPlayer(client);
      if (!player) return;
      this.pushCardToHand(player, makeCard("added", cardUid), client);
    },
  };

  onCreate() {
    this.state.round = 0;
  }

  onJoin(client: Client) {
    const player = new Player();
    player.sessionId = client.sessionId;
    player.handCount = 0;

    this.state.players.set(client.sessionId, player);

    // Set up StateView — client can see their own hand
    client.view = new StateView();
    client.view.add(player);

    // Deal initial hand (3 cards)
    const colors = ["red", "blue", "green"];
    for (let i = 0; i < 3; i++) {
      this.pushCardToHand(player, makeCard(colors[i], i + 1), client);
    }

    // Add initial discard pile (2 cards)
    if (this.state.discardPile.length === 0) {
      this.state.discardPile.push(makeCard("discard", 1));
      this.state.discardPile.push(makeCard("discard", 2));
    }
  }

  onLeave(client: Client) {
    this.state.players.delete(client.sessionId);
  }
}
