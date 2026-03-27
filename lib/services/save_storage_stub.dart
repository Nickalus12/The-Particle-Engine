import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SaveStorage {
  SaveStorage(this.namespace);

  final String namespace;

  String _key(String name) => '$namespace::$name';

  Future<void> write(String name, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(name), value);
  }

  Future<void> writeAtomic(String name, String value) async {
    await write(name, value);
  }

  Future<String?> read(String name) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(name));
  }

  Future<bool> exists(String name) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key(name));
  }

  Future<int> length(String name) async {
    final value = await read(name);
    return value == null ? 0 : utf8.encode(value).length;
  }

  Future<void> delete(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(name));
  }
}

SaveStorage createSaveStorage() => SaveStorage('particle_engine_saves');
