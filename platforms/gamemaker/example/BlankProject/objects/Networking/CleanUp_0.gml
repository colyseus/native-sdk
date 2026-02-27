/// Clean Up Event — free resources
if (colyseus_room != 0) {
    colyseus_room_leave(colyseus_room);
    colyseus_room_free(colyseus_room);  // auto-frees callbacks
}
if (client != 0) {
    colyseus_client_free(client);
}
