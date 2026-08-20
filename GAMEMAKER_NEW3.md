THIS IS THE "BEST" VERSION SO FAR...

How Colyseus is making online multiplayer more accessible to GameMaker developers, by keeping the game's shared state on a server that decides what's real.

Multiplayer is one of the most requested, most exciting, and often most intimidating features for independent game developers. For GameMaker creators, the arrival of the Colyseus GameMaker extension opens up a new route into real-time online play, connecting their games to an open-source multiplayer framework. One word of warning before we start, because it trips up every GameMaker dev: when Colyseus says "room" it does not mean a level in the room editor. A Colyseus room is a live game session on the server (a match, a table, a dungeon) that players connect to. We spoke to the Colyseus team about what the extension makes possible, why GameMaker support matters, and how developers can start today.

1. For GameMaker developers discovering Colyseus for the first time, how would you explain what it is and what problem it solves?

Colyseus is the multiplayer server for your game. On the server you change a normal data structure (a player's position, a score, a hand of cards) and Colyseus sends only what changed to each client. You write game logic, not networking code. That's the part that catches people off guard, in a good way. Around it, Colyseus handles the rest of what every online game needs: matchmaking, deciding whether a player can join a session, and keeping every connected client in sync.

Yes, the server is written in JavaScript (it runs on Node.js, a way to run JavaScript outside the browser). Be honest with us, you ask: do I have to learn JavaScript? A bit, yes, your game's rules live on the server. But you don't start from a blank file. A one-line command scaffolds a working server for you, and our two demos (a card game and a tanks game) ship with servers you can read and adapt. You'll recognise more of it than you'd expect: it's loops, structs, and functions, not networking plumbing.

2. Why was it important for Colyseus to support GameMaker specifically?

Our mission is to let developers build multiplayer games regardless of which engine they work in, so we maintain one shared client that we bring to each engine. GameMaker is the latest. GameMaker and Colyseus draw from the same crowd: indie developers and small teams. Bringing the two together means those developers get online multiplayer without leaving the tools they know.

3. Multiplayer can feel intimidating for solo developers and small teams. What are the biggest barriers Colyseus helps remove?

Two things. First, scaling, the part of running servers that handles a crowd. When your game gets popular (exactly when you don't want a new problem) more players need more server capacity. Colyseus is built to scale from the start, so it isn't something you have to get right on day one.

Second, the number of upfront decisions. Multiplayer has real limits (you can't cheaply sync thousands of moving things across the network at once, for instance), and many early choices come down to working within them. Colyseus has already made most of those decisions for you, so you can focus on how your game plays and feels. How your data gets packed and sent down the wire is our problem, not yours.

4. What kinds of GameMaker games are the best fit for Colyseus?

Anything session-based, which is most of what indie teams make. As we said up top, a Colyseus room corresponds neatly to a match, a round, a table, a dungeon, one self-contained game session. Real-time action works — arena brawlers, shooters, racing — and so do turn-based formats like card games, board games, and strategy titles.

The one thing it isn't built for is a single massive seamless world holding thousands of players at once. Even there, the common workaround is to split the world into regions and run each as its own room. For the session-based games most solo and small teams set out to make, the room model maps onto what they need without a fight.

5. What does the GameMaker extension actually give developers inside their project?

A complete GML API for multiplayer, and it lives where you'd expect: in your event code. In a Create event you connect; in the Step event you pump the connection once a frame; everywhere else you react to callbacks. A callback is just a function you hand to Colyseus that it calls back when something happens. The shape is always the same:

```gml
// Create event: connect, then join a session called "battle"
client = colyseus_client_create("http://localhost:2567");
net_room = colyseus_client_join_or_create(client, "battle", {});

// react to messages from the server — you get the type, and branch on it
colyseus_on_message(net_room, function(_room, _type, _payload) {
    if (_type == "game_over") show_message("Winner: " + _payload.winner);
});

// Step event: let Colyseus deliver everything that arrived this frame
colyseus_process();
```

That `join_or_create` call is also your matchmaking: it joins an existing room or spins up a new one, so you never build lobby code. Pass options in that struct and you can match on criteria like game mode or region. The single `colyseus_process()` call in your Step event is what fires all your callbacks, so it fits GameMaker's frame loop neatly, with no threads or async surprises to manage.

Beyond connecting and messaging, you get a live, readable copy of the game session's state with callbacks for changes ("a player was added", "this value changed"); a way to make plain web requests to a server if your game needs one; a login that's remembered between game launches (only if your game needs accounts, many don't); and automatic reconnection that queues your outgoing messages while the connection is down. A wifi blip doesn't have to end the match. The same GML code runs on Windows, macOS, Linux, HTML5, and GX.Games, with mobile support still to come.

6. How does Colyseus's room-based architecture help developers structure multiplayer games?

By now you know what a room is: one live game session. The key detail is that each room has its own state and its own logic, completely sealed off from every other room, and the server creates and disposes them on demand as players come and go. You never manage that lifecycle yourself.

That buys you two things. It keeps your code simple, because you only ever reason about one match at a time (the players in this room, the deck in this room) rather than everything at once. And it scales well, since rooms are independent: spread enough of them out and you can host a lot of games at once.

7. Colyseus is built around server-authoritative multiplayer. Why does that matter for fairness, consistency, and cheat prevention?

Clients never declare facts like "I'm now at this position" or "I drew a wild card". Instead, they send intents like "I want to move" or "I want to play this card", and the server decides what actually happens. That distinction is everything for cheating: players can modify anything running on their own machine, so any state a client controls is state a cheater controls. With the server in charge, lying about your score or position simply doesn't work.

It also keeps everyone consistent: there's one version of the game state, and all players see it, so clients can never drift apart. And it enables hidden information, which games that trust one player's machine to run the match struggle with: in our card game demo, the server owns the deck and tells each player only their own hand; everyone else just sees card counts. How strict you are is up to you: relaxed for a co-op game between friends, locked down for anything competitive.

8. What does real-time state synchronisation mean in practical terms for a GameMaker developer?

It means you don't write the code that syncs your game state across the network. The state lives on the server, where you list the fields it holds (players, positions, scores) and your server code changes them like ordinary data, the JavaScript side we talked about earlier. Clients never change it directly; they just receive the results. Colyseus watches for those changes and sends each client a compact binary patch (a tiny diff) containing only what changed.

In GameMaker, that arrives as callbacks. A player joins the room state? Your `on_add` callback fires and you spawn an instance. Their `x` changes? Your listener fires and you move the sprite. They leave? `on_remove` fires and you destroy it. There are no packet formats to design, no serialisation code, no "did I forget to send that update" bugs. The state behaves like a shared data structure the server writes and every client reads.

What's still your job is presentation, and only if you want it. For fast-paced games you'll typically smooth (interpolate) between the updates as they arrive, so movement looks fluid instead of stepping from one server snapshot to the next. The most demanding games may go further and predict the next moment locally. Both are optional polish you add later, on state that's already correct and in sync.

9. How should developers think about hosting and deploying a Colyseus multiplayer server?

Don't let hosting scare you off, and the easiest answer comes first: if you'd rather not touch servers at all, Colyseus Cloud is our managed option where you deploy in a few minutes and we handle scaling, security certificates, and monitoring for you. Many developers start there and never look back.

If you want to run it yourself, here's the whole first session. Install Node.js once from nodejs.org. Then create a server and start it:

```
npm create colyseus-app@latest my-server
cd my-server
npm start
```

That's it: your server is now running on your own machine, and your GameMaker project connects to it at `localhost` (the address that means "this same computer"). Edit, save, restart, repeat. One piece of advice while you're local: turn on the built-in latency simulation to mimic real-world lag (the delay between player and server). A game that feels great at zero latency on your own machine can feel very different once there's 100ms between player and server, and catching that early saves you painful surprises later.

When you're ready for the internet, anything that runs Node.js works, from a cheap rented server to any cloud provider. Self-hosting is completely free, with no lock-in. Either way, the server code you write is identical.

10. The GameMaker extension is currently in beta. What should developers expect at this stage, and what feedback would be most useful from the community?

What beta means here: it works, and what it needs now is real games putting it through its paces. The core underneath is shared with our other native SDKs, so that part is well-exercised; the GameMaker binding on top is the newer piece. Colyseus itself is still pre-1.0, though we're very close now, so the API can still shift a little between versions as we settle the last details before 1.0. Windows, macOS, Linux, HTML5, and GX.Games all work today; iOS and Android aren't tested yet. The honest expectation: things work, but you may hit the occasional bug or a breaking change. Whenever an upgrade needs migration steps, we'll document them.

The most useful feedback comes from people building real prototypes. Tell us where the GML API feels awkward, where the documentation let you down, or anything weird in packaging or on a specific platform. GitHub issues and our Discord are the places to reach us, and we read everything.

And if reading about all this is more daunting than seeing it, skip ahead: the best way to start is to open our two GameMaker demos, a turn-based card game and a real-time tanks game, each with a working server and working GML alongside it. Between them they put the ideas from this interview into practice: the server deciding what's real, hidden information, bots that fill empty seats until humans join, and dropped players who can rejoin without resetting the session. They're built as reference material, so you can study how each piece works and adapt the patterns into your own game. Two working examples beat any amount of prose, including ours.

---

Links for the post (reference, not part of the answers):

- GameMaker SDK docs: https://docs.colyseus.io/getting-started/gamemaker
- Colyseus on GitHub: https://github.com/colyseus/colyseus
- Discord: https://discord.gg/RY8rRS7
- Turn-based Cards Demo (UNO): https://github.com/colyseus/turnbased-cards-demo/tree/main/gamemaker
- Realtime Tanks Demo: https://github.com/colyseus/realtime-tanks-demo/tree/master/gamemaker
