THIS IS THE BAD SESSION FROM CLAUDE USING "CONVERSATIONAL" TONE

How Colyseus is making online multiplayer more accessible to GameMaker developers, by keeping the game's shared state on a server that decides what's real.

Multiplayer is one of the most requested, most exciting, and often most intimidating features for independent game developers. For GameMaker creators, the arrival of the Colyseus GameMaker extension opens up a new route into real-time online play, connecting their games to an open-source multiplayer framework. One word of warning before we start, because it trips up every GameMaker dev: when Colyseus says "room" it does not mean a level in the room editor. A Colyseus room is a live game session on the server (a match, a table, a dungeon) that players connect to. We spoke to the Colyseus team about what the extension makes possible, why GameMaker support matters, and how developers can start today.

1. For GameMaker developers discovering Colyseus for the first time, how would you explain what it is and what problem it solves?

Colyseus is the multiplayer server for your game. What surprises people is how ordinary it feels to work with. On the server, you change a normal data structure (a player's position, a score, a hand of cards), and Colyseus figures out what changed and sends only that to each client. You write game logic, not networking code. Around that, it quietly handles the rest of what every online game needs: matchmaking, deciding who can join a session, and keeping every connected player in sync.

The question we always get next is whether you'll have to learn JavaScript. A little, yes: your game's rules run on the server, and the server is JavaScript (on Node.js, which is just a way to run JavaScript outside the browser). But you're never staring at a blank file. One command scaffolds a working server for you, and both demos (a card game and a tanks game) come with servers you can open, read, and adapt. Most GameMaker developers find it more familiar than they expect: loops, structs, and functions, not networking plumbing.

2. Why was it important for Colyseus to support GameMaker specifically?

We already share an audience. Colyseus and GameMaker both attract indie developers and small teams shipping focused games, and many of the people asking us for multiplayer were already working in GameMaker. It's been a long-standing request, and what finally made it practical was rebuilding our client as a single shared core in C: once that existed, adding an engine meant writing a thin binding to it rather than a whole client from scratch. GameMaker is the latest to get one, so its developers can add online multiplayer without leaving the tools they already know.

3. Multiplayer can feel intimidating for solo developers and small teams. What are the biggest barriers Colyseus helps remove?

Two things. The first is scaling. When your game catches on (exactly when you don't want a new problem) more players need more server capacity. Colyseus is built to scale from the start, so it isn't something you have to get right on day one.

The second is the number of decisions you face up front. Multiplayer comes with real limits, and many early choices come down to working within them: you can't cheaply sync thousands of moving things across the network at once, for instance. We've already made most of those calls for you, so you can focus on how your game plays and feels. How the data gets packed and sent down the wire is our problem, not yours.

4. What kinds of GameMaker games are the best fit for Colyseus?

Most of what indie teams already build. Anything session-based is a natural fit, because a Colyseus room maps neatly onto a single match or round. Real-time action works well (arena brawlers, shooters, racing), and so do turn-based formats like card games, board games, and strategy titles.

The one thing it isn't suited to is a single massive seamless world with thousands of players in it at once. Even there, the usual workaround is to split the world into regions and run each as its own room. For the session-based games most solo and small teams set out to make, the room model fits what they need without a fight.

5. What does the GameMaker extension actually give developers inside their project?

A complete GML API for multiplayer, and it lives exactly where you'd expect: in your event code. You connect in a Create event, you pump the connection once a frame in the Step event, and everywhere else you react to callbacks. A callback is just a function you hand to Colyseus for it to call back when something happens. The shape is always the same:

```gml
// Create event: connect, then join a session called "battle"
client = colyseus_client_create("http://localhost:2567");
net_room = colyseus_client_join_or_create(client, "battle", {});

// react to messages from the server: you get the type, and branch on it
colyseus_on_message(net_room, function(_room, _type, _payload) {
    if (_type == "game_over") show_message("Winner: " + _payload.winner);
});

// Step event: let Colyseus deliver everything that arrived this frame
colyseus_process();
```

That `join_or_create` call is also your matchmaking: it joins an existing room or spins up a new one, so you never build lobby code. Pass options in that struct and you can match on criteria like game mode or region. The single `colyseus_process()` call in your Step event is what fires all your callbacks, so it fits GameMaker's frame loop neatly, with no threads or async surprises to manage.

Beyond connecting and messaging, you get a live, readable copy of the game session's state, with callbacks that fire on every change ("a player was added", "this value changed"). You also get a few things to reach for when a game needs them: plain web requests to your own server, and a login that persists between launches for the games that want accounts (many don't). And you get automatic reconnection that queues your outgoing messages while the connection is down, so a wifi blip doesn't have to end the match. The same GML code runs on every GameMaker export target, with mobile still to come.

6. How does Colyseus's room-based architecture help developers structure multiplayer games?

Each room is completely sealed off from the others: its own state, its own logic, nothing leaking between them. The server spins them up and tears them down on demand as players come and go, so the whole lifecycle is handled for you.

That buys you two things. Your code stays simple, because you only ever think about one match at a time (the players in this room, the deck in this room) instead of everything at once. And it scales naturally, since rooms are independent: spread enough of them across machines and you can host a lot of games at once.

7. Colyseus is built around server-authoritative multiplayer. Why does that matter for fairness, consistency, and cheat prevention?

Clients never declare facts like "I'm now at this position" or "I drew a wild card". Instead, they send intents like "I want to move" or "I want to play this card", and the server decides what actually happens. (A client here is the copy of the game running on a player's machine.) That distinction is everything for cheating: a player can modify anything on their own machine, so any state a client controls is state a cheater controls. With the server in charge, lying about your score or position simply doesn't work.

It also keeps everyone consistent: there's one version of the game state, and all players see it, so clients can never drift apart. And it enables hidden information. Suppose the match runs on one player's machine instead of the server: that machine has to know every card to run the game, so it can leak them. The server-authoritative version closes that gap. In our card game demo, the server owns the deck and tells each player only their own hand; everyone else just sees card counts. How strict you are is up to you: relaxed for a co-op game between friends, locked down for anything competitive.

8. What does real-time state synchronisation mean in practical terms for a GameMaker developer?

It means you don't write the code that syncs your game state across the network. The state lives on the server, where you list the fields it holds (players, positions, scores) and your server code changes them like ordinary data. Clients never change it directly; they just receive the results. Colyseus watches for those changes and sends each client a compact binary patch (a tiny diff) containing only what changed.

In GameMaker, that arrives as callbacks. A player joins the room state? Your `on_add` callback fires and you spawn an instance. Their `x` changes? Your listener fires and you move the sprite. They leave? `on_remove` fires and you destroy it. There are no packet formats to design, no serialisation code, no "did I forget to send that update" bugs. The state behaves like a shared data structure the server writes and every client reads.

What's still your job is presentation, and only if you want it. For fast-paced games you'll typically smooth (interpolate) between the updates as they arrive, so movement looks fluid instead of stepping from one server snapshot to the next. The most demanding games may go further and predict the next moment locally. Both are optional polish you add later, on state that's already correct and in sync.

9. How should developers think about hosting and deploying a Colyseus multiplayer server?

If you'd rather not touch servers at all, start with Colyseus Cloud, our managed option: you deploy in a few minutes and we handle scaling, security certificates, and monitoring for you. Many developers start there and never look back.

If you want to run it yourself, here's the whole first session. Install Node.js once from nodejs.org. Then create a server and start it:

```
npm create colyseus-app@latest my-server
cd my-server
npm start
```

That's it: your server is now running on your own machine, and your GameMaker project connects to it at `localhost` (the address that means "this same computer"). Edit, save, restart, repeat. One piece of advice while you're local: turn on the built-in latency simulation to mimic real-world lag (the delay between player and server). A game that feels great at zero latency on your own machine can feel very different once there's 100ms between player and server, and catching that early saves you painful surprises later.

When you're ready for the internet, anything that runs Node.js works, from a cheap rented server to any cloud provider. Self-hosting is completely free, with no lock-in. Either way, the server code you write is identical.

10. The GameMaker extension is currently in beta. What should developers expect at this stage, and what feedback would be most useful from the community?

What beta means here: it works, and what it needs now is real games putting it through its paces. The core underneath is shared with our other native SDKs, so that part is well-exercised; the GameMaker binding on top is the newer piece. Colyseus itself is still pre-1.0, though we're very close now, so the API can still shift a little between versions as we settle the last details. Windows, macOS, Linux, HTML5, and GX.Games all work today; iOS and Android we haven't tested yet. The honest expectation: things work, but you may hit the occasional bug or a breaking change, and whenever an upgrade needs migration steps, we'll document them.

The most useful feedback comes from people building real prototypes, so the best way in is to open our two GameMaker demos: a turn-based card game and a real-time tanks game, each with a working server and working GML alongside it. Between them they put the ideas from this interview into practice: the server deciding what's real, hidden information, bots that fill empty seats until humans join, and dropped players who can rejoin without resetting the session. They're built as reference material, so you can study how each piece works and adapt the patterns into your own game. Two working examples beat any amount of prose, including ours.

Once you're building, tell us where the GML API feels awkward, where the documentation let you down, or anything weird in packaging or on a specific platform. GitHub issues and our Discord are the places to reach us, and we read everything.

---

Links for the post (reference, not part of the answers):

- GameMaker SDK docs: https://docs.colyseus.io/getting-started/gamemaker
- Colyseus on GitHub: https://github.com/colyseus/colyseus
- Discord: https://discord.gg/RY8rRS7
- Turn-based Cards Demo (UNO): https://github.com/colyseus/turnbased-cards-demo/tree/main/gamemaker
- Realtime Tanks Demo: https://github.com/colyseus/realtime-tanks-demo/tree/master/gamemaker
