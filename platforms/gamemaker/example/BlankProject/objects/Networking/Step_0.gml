/// Step Event — process all queued Colyseus events
colyseus_process();

// Auto-exit after GMTL tests finish
if (gmtl_has_finished) {
    game_end();
    exit;
}

// Send "move" message on arrow key press (skip during headless test runs)
if (!gmtl_has_finished && colyseus_room != -1 && colyseus_room_is_connected(colyseus_room)) {
    try {
        var _dx = keyboard_check(vk_right) - keyboard_check(vk_left);
        var _dy = keyboard_check(vk_down) - keyboard_check(vk_up);
        if (_dx != 0 || _dy != 0) {
            x += _dx * 4;
            y += _dy * 4;
            colyseus_send(colyseus_room, "move", { x: x, y: y });
        }
    } catch(_e) { /* headless runner — keyboard_check unavailable */ }
}
