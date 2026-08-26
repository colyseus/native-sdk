Multiplayer is one of the most requested, most exciting, and often most intimidating features for independent game developers. For GameMaker creators, the arrival of the Colyseus GameMaker extension opens up a new route into real-time online play, giving developers a way to connect their games to an open-source multiplayer framework built around rooms, matchmaking, state synchronisation, and server-authoritative game logic. We spoke to the Colyseus team about what the extension makes possible, why GameMaker support matters, and how developers can start experimenting with online multiplayer today.


1. For GameMaker developers discovering Colyseus for the first time, how would you explain what it is and what problem it solves?

Colyseus is an open-source multiplayer framework that handles the hard parts of real-time online games for you. When you make a multiplayer game, you quickly run into a problem: the players' devices can't just talk to each other directly and trust whatever they say—you need a central authority that holds the "true" game state, decides what's valid, and keeps everyone in sync. That's a server, and writing one from scratch means dealing with networking, connection handling, room management, state synchronisation, and a lot of edge cases.

Colyseus gives you all of that out of the box. You write your authoritative game logic on a Node.js server using the Colyseus framework, and it takes care of the messy infrastructure underneath—rooms, matchmaking, client connections, and efficiently syncing state to every player. The framework was designed to be approachable, so even if you've never touched Node.js or TypeScript before, you can get a server running and reason about what it's doing without becoming a backend engineer first.


2. Why was it important for Colyseus to support GameMaker specifically?

GameMaker support is something our community has asked us for over many years. We even saw people pulling off some wonderfully strange hacks to get Colyseus working in HTML5 builds before we had the SDK. It also aligns with our mission: we want developers to use Colyseus regardless of which engine they work in - multiplayer shouldn't be locked behind a particular tech stack.

3. Multiplayer can feel intimidating for solo developers and small teams. What are the biggest barriers Colyseus helps remove?

Multiplayer introduces two kinds of hard problems at once: gameplay and infrastructure. On the gameplay side, you have to think about authority, state synchronisation, latency, and what happens when players disconnect or join mid-game. On the infrastructure side, you need a server that can handle connections, spin up rooms, match players together, and scale when more people show up. For a solo developer or small team, that's a lot to take on alongside actually making the game.

Colyseus has already made many of those decisions for you, so instead of designing a networking architecture from scratch, you lean on patterns known to work and focus your energy on your actual game. The intimidating sense that you need to be a backend expert before you can even start mostly falls away.

4. What kinds of GameMaker games are the best fit for Colyseus?

Anything naturally built around sessions of players: co-op games, turn-based card and board games, party games, arena and .io-style games, virtual hangout spaces. Small groups — say two to sixteen players per room — are the sweet spot, though rooms can hold more.

Turn-based games are probably the gentlest entry point, because the pacing is forgiving while you learn — that's why our open-source UNO demo is a card game. Real-time games work great too; the server broadcasts state changes many times per second and clients interpolate between them.

To be honest about the other end: very twitchy, physics-heavy games that need rollback netcode — fighting games being the classic example — are a harder fit for this architecture. But in our experience, the overwhelming majority of indie multiplayer ideas are room-shaped.

5. What does the GameMaker extension actually give developers inside their project?

A complete GML API for multiplayer. You create a client, call `colyseus_client_join_or_create()` with a room name, and register handlers like `colyseus_on_state_change()` and `colyseus_on_message()`. One call to `colyseus_process()` in a Step event dispatches everything — it fits GameMaker's frame loop neatly, with no threads or async surprises to manage.

Under the hood, the extension ships native libraries for Windows, macOS, and Linux compiled from our C core, plus a JavaScript implementation for HTML5 and GX.Games — the same GML code runs everywhere, and mobile support is on the way. Beyond connecting and messaging, you get typed access to the synchronised game state with callbacks for changes ("a player was added", "this value changed"), an HTTP API for talking to your backend, auth tokens that persist between game launches, and automatic reconnection that queues your outgoing messages while the connection is down — a wifi blip doesn't have to end the match.


6. How does Colyseus's room-based architecture help developers structure multiplayer games?

A room is one running instance of your game — a match, a lobby, a dungeon, a table at a card game. Each room has its own state and its own logic, completely isolated from every other room, and the server creates and disposes them on demand as players come and go — you never manage that lifecycle yourself.

This does two nice things. It keeps your code simple, because you only ever reason about one match at a time — "the players in this room, the deck in this room" — rather than one giant world. And it scales well, since rooms are independent and can be spread across processes and machines.


7. Colyseus is built around server-authoritative multiplayer. Why does that matter for fairness, consistency, and cheat prevention?

Server-authoritative means the server owns the truth. Clients don't say "I'm now at this position" or "I drew a wild card" — they send intents, like "I want to move" or "I want to play this card", and the server decides what actually happens. Since players can modify anything running on their own machine, any state a client controls is state a cheater controls. With the server in charge, lying about your score or position simply doesn't work.

It also keeps everyone consistent: there's one version of the game state, and all players see it, so clients can never drift apart. And it enables hidden information, which client-hosted games struggle with — in our UNO demo, the server owns the deck and tells each player only their own hand; everyone else just sees card counts. How strict you are is up to you: relaxed for a co-op game between friends, locked down for anything competitive.


8. What does real-time state synchronisation mean in practical terms for a GameMaker developer?

It means you never write netcode for your game state. On the server, you declare what the state looks like — players, positions, scores — and your game logic just mutates it like ordinary data. Colyseus watches for changes and sends each client a compact binary patch containing only what changed.

In GameMaker, that arrives as callbacks. A player joins the room state? Your `on_add` callback fires and you spawn an instance. Their `x` changes? Your listener fires and you move the sprite. They leave? `on_remove` fires and you destroy it. There are no packet formats to design, no serialisation code, no "did I forget to send that update" bugs. The state behaves like a shared data structure the server writes and every client reads — your GameMaker project's job is just to draw it.


9. How should developers think about hosting and deploying a Colyseus multiplayer server?

Don't let hosting scare you off — your server is a standard Node.js application, and during development it just runs on your own machine. You `npm start`, point your GameMaker project at `localhost`, and iterate. Our advice is to stay there until your game is actually fun; deployment can wait.

When you're ready for the internet, anything that runs Node.js works: a cheap VPS, Docker, any cloud provider. Self-hosting is completely free, and since the whole framework is open source there's no lock-in. If you'd rather not manage servers at all, there's also Colyseus Cloud, our managed offering — you deploy in a few minutes and scaling, TLS, and monitoring are handled for you. Either way, the server code you write is identical.


10. The GameMaker extension is currently in beta. What should developers expect at this stage, and what feedback would be most useful from the community? (Maybe mention the UNO template example project here too)

Beta means the core is solid but we're still sanding the edges. The API mirrors our mature SDKs — it's the same 0.17 series as our JavaScript client — and Windows, macOS, Linux, HTML5, and GX.Games all work today, with iOS and Android on the way. The honest expectation: things work, but you may hit the occasional bug or breaking change between versions.

The most useful feedback comes from people building real prototypes. Tell us where the GML API feels awkward, where the documentation let you down, anything weird in packaging or on a specific platform — GitHub issues and our Discord are the places, and we read everything.

The best way to start is our UNO template: a complete UNO-style card game with a GameMaker client that puts the ideas from this interview into practice — server-authoritative rules, hidden information, bots that fill empty seats until humans join, and a dropped player can rejoin without resetting the table. Clone it, reskin it, and make it yours.


---

Links for the post (reference, not part of the answers):

- UNO template: https://github.com/colyseus/turnbased-cards-demo
- GameMaker SDK docs: https://docs.colyseus.io/getting-started/gamemaker
- Colyseus on GitHub: https://github.com/colyseus/colyseus
- Discord: https://discord.gg/RY8rRS7
