How Colyseus is making authoritative multiplayer, matchmaking, and real-time state sync more accessible to GameMaker developers.

Multiplayer is one of the most requested, most exciting, and often most intimidating features for independent game developers. For GameMaker creators, the arrival of the Colyseus GameMaker extension opens up a new route into real-time online play, giving developers a way to connect their games to an open-source multiplayer framework built around rooms, matchmaking, state synchronisation, and server-authoritative game logic. We spoke to the Colyseus team about what the extension makes possible, why GameMaker support matters, and how developers can start experimenting with online multiplayer today.

1. For GameMaker developers discovering Colyseus for the first time, how would you explain what it is and what problem it solves?

Colyseus is an open-source framework for building real-time multiplayer games, the kind where one player makes a move and everyone else sees it right away. For that to work, every player has to agree on what's happening, moment to moment, and Colyseus makes that happen with an authoritative server that holds the "true" game state in memory and stays in sync with every client over a persistent WebSocket. On your own, you'd build that server and then keep it running as players connect, drop, and rejoin mid-match. Colyseus handles all of that for you, so you can focus on writing your game's rules.

That server is a separate application from your GameMaker project, with its own tooling, written in Node.js and TypeScript. We built it so you don't need experience with either to get started, though. And because it's open source, it's yours to deploy on any cloud provider you like.

2. Why was it important for Colyseus to support GameMaker specifically?

GameMaker support is something our community has asked us for over many years. We even saw people pulling off some wonderfully strange hacks to get Colyseus working in HTML5 builds before we had the SDK. What finally made a proper extension feasible was rebuilding our client as a shared core in C, which now powers all our native SDKs, GameMaker included. It also aligns with our mission: we want developers to use Colyseus regardless of which engine they work in. Multiplayer shouldn't be locked behind a particular tech stack.

3. Multiplayer can feel intimidating for solo developers and small teams. What are the biggest barriers Colyseus helps remove?

Multiplayer introduces two kinds of hard problems at once: gameplay and infrastructure. On the gameplay side, you have to think about authority, latency, and what happens when players disconnect or join mid-game. On the infrastructure side, you need a server that can handle connections, spin up rooms, and match players together. For a solo developer or small team, that's a lot to take on alongside actually making the game.

Colyseus has already made many of those decisions for you, so rather than designing your own networking architecture, you lean on patterns known to work and focus your energy on your actual game. The intimidating sense that you need to be a backend expert before you can even start mostly falls away.

4. What kinds of GameMaker games are the best fit for Colyseus?

Colyseus is built around rooms, which makes it a natural fit for any GameMaker game that's session-based. That covers a wide range, from real-time action like arena brawlers, shooters, and racing games, to turn-based formats like card games, board games, and strategy titles.

You can't easily make a massive seamless world with thousands of players in one persistent space, but there's a common workaround: split the world into smaller regions and treat each as its own room. For the session-based games most solo and small teams are building, the room model maps cleanly onto what they need.

5. What does the GameMaker extension actually give developers inside their project?

A complete GML API for multiplayer. You create a client and call `colyseus_client_join_or_create()` with a room name. That call is your matchmaking: it joins an existing room, or spins up a new one, so you never build lobby infrastructure. Pass options and you can match on criteria like game mode or region, not just by room name. Then you register handlers like `colyseus_on_state_change()` and `colyseus_on_message()`. One call to `colyseus_process()` in a Step event dispatches everything. It fits GameMaker's frame loop neatly, with no threads or async surprises to manage.

Under the hood, the extension ships native libraries for Windows, macOS, and Linux compiled from our C core, plus a WebAssembly build of that same core for HTML5 and GX.Games. The same GML code runs everywhere, with mobile support still to come. Beyond connecting and messaging, you get typed access to the synchronised game state with callbacks for changes ("a player was added", "this value changed"), an HTTP API for talking to your backend, auth tokens that persist between game launches, and automatic reconnection that queues your outgoing messages while the connection is down. A wifi blip doesn't have to end the match.

6. How does Colyseus's room-based architecture help developers structure multiplayer games?

A room is one running instance of your game: a match, a lobby, a dungeon, a table at a card game. Each room has its own state and its own logic, completely isolated from every other room, and the server creates and disposes them on demand as players come and go. You never manage that lifecycle yourself.

This does two nice things. It keeps your code simple, because you only ever reason about one match at a time (the players in this room, the deck in this room) rather than everything at once. And it scales well, since rooms are independent and can be spread across processes and machines.

7. Colyseus is built around server-authoritative multiplayer. Why does that matter for fairness, consistency, and cheat prevention?

Clients never declare facts like "I'm now at this position" or "I drew a wild card". Instead, they send intents like "I want to move" or "I want to play this card", and the server decides what actually happens. That distinction is everything for cheating: players can modify anything running on their own machine, so any state a client controls is state a cheater controls. With the server in charge, lying about your score or position simply doesn't work.

It also keeps everyone consistent: there's one version of the game state, and all players see it, so clients can never drift apart. And it enables hidden information, which client-hosted games struggle with: in our card game demo, the server owns the deck and tells each player only their own hand; everyone else just sees card counts. How strict you are is up to you: relaxed for a co-op game between friends, locked down for anything competitive.

8. What does real-time state synchronisation mean in practical terms for a GameMaker developer?

It means you don't write the code that syncs your game state across the network. The state lives on the server: you declare what it looks like (players, positions, scores) and your server-side logic mutates it like ordinary data. Clients never change it directly; they just receive the results. Colyseus watches for those changes and sends each client a compact binary patch containing only what changed.

In GameMaker, that arrives as callbacks. A player joins the room state? Your `on_add` callback fires and you spawn an instance. Their `x` changes? Your listener fires and you move the sprite. They leave? `on_remove` fires and you destroy it. There are no packet formats to design, no serialisation code, no "did I forget to send that update" bugs. The state behaves like a shared data structure the server writes and every client reads.

What's still your job is presentation. For fast-paced games you'll typically interpolate or smooth between the updates as they arrive, so movement looks fluid instead of stepping from one server snapshot to the next. The most demanding games may layer prediction on top. But you do that on state that's already correct and in sync.

9. How should developers think about hosting and deploying a Colyseus multiplayer server?

Don't let hosting scare you off. Your server is a standard Node.js application, and during development it just runs on your own machine. You `npm start`, point your GameMaker project at `localhost`, and iterate. One piece of advice: while you're working locally, use the framework's built-in latency simulation to mimic real-world lag. A game that feels great at zero latency on localhost can feel very different once there's 100ms between player and server, and catching that early saves you painful surprises later.

When you're ready for the internet, anything that runs Node.js works: a cheap VPS, Docker, any cloud provider. Self-hosting is completely free, with no lock-in. If you'd rather not manage servers at all, there's also Colyseus Cloud, our managed offering, where you deploy in a few minutes and scaling, TLS, and monitoring are handled for you. Either way, the server code you write is identical.

10. The GameMaker extension is currently in beta. What should developers expect at this stage, and what feedback would be most useful from the community? 

The GameMaker SDK is one of our native SDKs, and what those still need is battle-testing in real games. Colyseus itself is still pre-1.0, though we're very close now, so the API can still shift a little between versions as we settle the last details before 1.0. Windows, macOS, Linux, HTML5, and GX.Games all work today, with iOS and Android yet to be tested. The honest expectation: things work, but you may hit the occasional bug or a breaking change. Whenever an upgrade needs migration steps, we'll document them.

The most useful feedback comes from people building real prototypes. Tell us where the GML API feels awkward, where the documentation let you down, or anything weird in packaging or on a specific platform. GitHub issues and our Discord are the places to reach us, and we read everything.

The best way to start is our two GameMaker demos: a turn-based card game and a real-time tanks game. Between them they put the ideas from this interview into practice: server-authoritative rules, hidden information, bots that fill empty seats until humans join, and dropped players who can rejoin without resetting the session. They're built as reference material, so you can study how each piece works and adapt the patterns into your own game.

---

Links for the post (reference, not part of the answers):

- GameMaker SDK docs: https://docs.colyseus.io/getting-started/gamemaker
- Colyseus on GitHub: https://github.com/colyseus/colyseus
- Discord: https://discord.gg/RY8rRS7
- Turn-based Cards Demo (UNO): https://github.com/colyseus/turnbased-cards-demo/tree/main/gamemaker
- Realtime Tanks Demo: https://github.com/colyseus/realtime-tanks-demo/tree/master/gamemaker
