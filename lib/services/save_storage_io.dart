import 'dart:io';

import 'package:path_provider/path_provider.dart';

class SaveStorage {
  SaveStorage(this.directoryName);

  final String directoryName;
  String? _dirPath;

  Future<Directory> _getDir() async {
    if (_dirPath != null) {
      return Directory(_dirPath!);
    }
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/$directoryName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dirPath = dir.path;
    return dir;
  }

  Future<File> _file(String name) async {
    final dir = await _getDir();
    return File('${dir.path}/$name');
  }

  Future<void> write(String name, String value) async {
    final file = await _file(name);
    await file.writeAsString(value);
  }

  Future<void> writeAtomic(String name, String value) async {
    final file = await _file(name);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(value, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  }

  Future<String?> read(String name) async {
    final file = await _file(name);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<bool> exists(String name) async {
    final file = await _file(name);
    return file.exists();
  }

  Future<int> length(String name) async {
    final file = await _file(name);
    if (!await file.exists()) return 0;
    return file.length();
  }

  Future<void> delete(String name) async {
    final file = await _file(name);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

SaveStorage createSaveStorage() => SaveStorage('particle_engine_saves');
