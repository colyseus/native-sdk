var client = colyseus_client_create("localhost:2567", false);
var my_room = colyseus_client_join_or_create(client, "my_room", "{}");
