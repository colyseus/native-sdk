import 'package:flutter/material.dart';
import 'package:colyseus_flutter/colyseus_flutter.dart';

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
  ColyseusRoom? _room;
  final List<String> _log = [];
  bool _connecting = false;

  void _addLog(String msg) {
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

      final room = await _client!.joinOrCreate('my_room');
      _room = room;
      _addLog('Joined room: ${room.id}');
      _addLog('Session ID: ${room.sessionId}');

      room.onStateChange.listen((_) {
        _addLog('State changed');
      });

      room.onMessage('chat').listen((data) {
        _addLog('Chat: $data');
      });

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
    } catch (e) {
      _addLog('Error: $e');
    } finally {
      setState(() => _connecting = false);
    }
  }

  void _sendMessage() {
    _room?.send('chat', {'text': 'Hello from Flutter!'});
    _addLog('Sent chat message');
  }

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
                  onPressed: _room != null ? _sendMessage : null,
                  child: const Text('Send Chat'),
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
                'Room: ${_room!.name} | Connected: ${_room!.isConnected}',
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
