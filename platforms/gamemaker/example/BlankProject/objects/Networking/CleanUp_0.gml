/// Clean Up Event — free resources
if (room != 0) {
    colyseus_room_leave(room);
    colyseus_room_free(room);  // auto-frees callbacks
}
if (client != 0) {
    colyseus_client_free(client);
}
