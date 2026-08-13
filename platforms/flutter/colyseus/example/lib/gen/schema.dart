// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
// ignore_for_file: non_constant_identifier_names, constant_identifier_names

import 'package:colyseus/colyseus.dart';

final class Item extends SchemaRef {
  Item(super.handle);

  String get name => view.getString('name') ?? '';
  double get value => view['value'];
}

final class Player extends SchemaRef {
  Player(super.handle);

  double get x => view['x'];
  double get y => view['y'];
  bool get isBot => view.getBool('isBot');
  bool get disconnected => view.getBool('disconnected');
  ArraySchema<Item> get items => arrayOf('items', Item.new);
}

final class TestRoomState extends SchemaRef {
  TestRoomState(super.handle);

  MapSchema<Player> get players => mapOf('players', Player.new);
  Player? get host => refOf('host', Player.new);
  String get currentTurn => view.getString('currentTurn') ?? '';
}
