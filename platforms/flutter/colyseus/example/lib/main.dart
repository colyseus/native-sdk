import 'dart:math';

import 'package:flutter/material.dart';
import 'package:colyseus/colyseus.dart';

import 'gen/schema.dart';

void main() {
  runApp(const ColyseusExampleApp());
}

class ColyseusExampleApp extends StatelessWidget {
  const ColyseusExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Colyseus Flutter Example',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
      ),
      home: const RoomPage(),
    );
  }
}

class RoomPage extends StatefulWidget {
  const RoomPage({super.key});

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  ColyseusClient? _client;
  ColyseusRoom<TestRoomState>? _room;
  final List<String> _log = [];
  bool _connecting = false;
  final _rng = Random();

  /// The typed root state, or null before the first patch decodes.
  TestRoomState? get _state => _room?.state;

  /// This client's own entry, typed.
  Player? get _me {
    final room = _room;
    return room == null ? null : _state?.players[room.sessionId];
  }

  @override
  void initState() {
    super.initState();
    // Auto-connect so a plain `flutter run` exercises the whole path —
    // including the macOS sandbox's network.client entitlement, which unit
    // tests can't check because they run outside the sandbox.
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  void _addLog(String msg) {
    // ignore: avoid_print
    print('[colyseus-example] $msg');
    setState(() {
      _log.add(msg);
      if (_log.length > 50) _log.removeAt(0);
    });
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() => _connecting = true);

    try {
      _client = ColyseusClient('ws://localhost:2567');
      _addLog('Client created');

      final room = await _client!.joinOrCreate('my_room',
          stateType: TestRoomState.new);
      _room = room;
      _addLog('Joined room: ${room.id}');
      _addLog('Session ID: ${room.sessionId}');

      room.onStateChange.listen((_) => setState(() {}));

      room.onMessageAny.listen((entry) {
        _addLog('Message [${entry.key}]: ${entry.value}');
      });

      room.onError.listen((error) {
        _addLog('Error: $error');
      });

      room.onLeave.listen((code) {
        _addLog('Left room (code: $code)');
        setState(() {
          _room = null;
        });
      });

      // The join resolves on the seat confirmation, which can arrive before
      // the first state patch — bind once the state exists.
      final state = room.state ?? await room.onStateChange.first;
      _bindStateCallbacks(room, state);
    } catch (e) {
      _addLog('Error: $e');
    } finally {
      setState(() => _connecting = false);
    }
  }

  /// Schema callbacks, C#-style: `Callbacks.get(room)` and the typed field
  /// to observe. Keys and values are statically typed from the generated
  /// classes in `lib/gen/schema.dart`.
  void _bindStateCallbacks(ColyseusRoom room, TestRoomState state) {
    final callbacks = Callbacks.get(room);

    callbacks.onAdd(state.players, (sessionId, player) {
      final who = player.isBot ? 'bot' : 'player';
      _addLog('+ $who $sessionId at '
          '(${player.x.toStringAsFixed(0)}, ${player.y.toStringAsFixed(0)})');
    });

    callbacks.onRemove(state.players, (sessionId, player) {
      _addLog('- $sessionId removed');
    });

    callbacks.listen(state, 'currentTurn', (String turn, String? previous) {
      final from = (previous == null || previous.isEmpty) ? '(none)' : previous;
      _addLog('turn: $from -> $turn');
    });
  }

  void _move() {
    final x = _rng.nextInt(800), y = _rng.nextInt(600);
    _room?.send('move', {'x': x, 'y': y});
    _addLog('Sent move to ($x, $y)');
  }

  void _addBot() => _room?.send('add_bot');

  void _removeBot() => _room?.send('remove_bot', {'name': 'any'});

  void _leave() {
    _room?.leave();
  }

  @override
  void dispose() {
    _room?.dispose();
    _client?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Colyseus Flutter')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                ElevatedButton(
                  onPressed: _room == null && !_connecting ? _connect : null,
                  child: Text(_connecting ? 'Connecting...' : 'Connect'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _room != null ? _move : null,
                  child: const Text('Move'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _room != null ? _addBot : null,
                  child: const Text('Add Bot'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _room != null ? _removeBot : null,
                  child: const Text('Remove Bot'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _room != null ? _leave : null,
                  child: const Text('Leave'),
                ),
              ],
            ),
          ),
          if (_room != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Text(
                // Typed reads through the generated classes.
                'Room: ${_room!.name} | '
                'Players: ${_state?.players.length ?? 0} | '
                'Me: (${_me?.x.toStringAsFixed(0) ?? '-'}, '
                '${_me?.y.toStringAsFixed(0) ?? '-'})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: _log.length,
              itemBuilder: (context, index) {
                final logIndex = _log.length - 1 - index;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8.0, vertical: 2.0),
                  child: Text(
                    _log[logIndex],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
