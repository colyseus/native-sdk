1. 
Colyseus is the multiplayer server for your game. You run it as your authoritative server (it's written in JavaScript/Node.js), and it handles the parts every online game needs: matchmaking, deciding whether a player is allowed to join a room, and keeping every connected client in sync with the room's state. The part that catches people off guard is how that last piece feels to work with. On the server you change a normal data structure (a player's position, a score, a hand of cards) and Colyseus sends only what changed to each client. You write game logic, not networking code.

2. 
Our mission is to let developers build multiplayer games regardless of which engine they work in. That's what the Colyseus Native SDK is for: one client core we bind into each engine, with the GameMaker extension as one of those bindings. GameMaker and Colyseus draw from the same crowd: indie developers and small teams. Bringing the two together means those developers get online multiplayer without leaving the tools they know.

3. 
Two things. First, infrastructure and scaling. The moment you go multiplayer you're responsible for servers, rooms, and what happens when your game gets popular, which is exactly when you don't want that to become a problem. Colyseus is built around scaling from the start, so it isn't a decision you have to get right on day one.
  
Second, the number of upfront decisions. Multiplayer has real limits (you can't cheaply sync thousands of objects across the network, for instance), and many early choices come down to working within them. Colyseus has already made most of those decisions for you, so you can focus on how your game plays and feels instead of how your data is shaped at the byte level.