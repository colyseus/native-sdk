/// Step Event — process all queued Colyseus events
colyseus_process();

// Send "move" message on arrow key press
if (colyseus_room_is_connected(colyseus_room)) {
    var _dx = keyboard_check(vk_right) - keyboard_check(vk_left);
    var _dy = keyboard_check(vk_down) - keyboard_check(vk_up);
    if (_dx != 0 || _dy != 0) {
        x += _dx * 4;
        y += _dy * 4;
        colyseus_send(colyseus_room, "move", { x: x, y: y });
    }
}
