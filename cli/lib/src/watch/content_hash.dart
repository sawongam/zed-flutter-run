import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Remembers the SHA-256 of each file's last seen content. Memory is bounded:
/// the least recently used entries are dropped beyond [maxEntries].
class ContentHashTracker {
  ContentHashTracker({
    Future<List<int>?> Function(String path)? readFile,
    this._maxBytes = 2 * 1024 * 1024,
    this.maxEntries = 5000,
  }) : _customReader = readFile != null {
    _readFile = readFile ?? _readLimited;
  }

  final int _maxBytes;
  final bool _customReader;
  final int maxEntries;
  late final Future<List<int>?> Function(String path) _readFile;
  final Map<String, String> _hashes = {};

  static const String _deleted = 'deleted';
  static const String _tooBig = 'too-big';

  /// True when the content at [path] differs from what was last seen.
  /// Missing files count as changed once; files larger than the limit always
  /// count as changed.
  ///
  /// [key] identifies the file in the store (default [path]); callers pass a
  /// normalised key so differently spelled paths share one entry.
  Future<bool> hasChanged(String path, {String? key}) async {
    key ??= path;
    List<int>? bytes;
    try {
      bytes = await _readFile(path);
    } on Object {
      bytes = null;
    }
    final String current;
    if (bytes == null) {
      current = _deleted;
    } else if (bytes.length > _maxBytes) {
      _store(key, _tooBig);
      return true;
    } else {
      current = sha256.convert(bytes).toString();
    }
    final previous = _hashes[key];
    _store(key, current);
    return previous != current;
  }

  /// Records the current content of [files] (path to key, as for
  /// [hasChanged]) as seen. With the default reader the files are read and
  /// hashed on a background isolate: a large `lib/` takes hundreds of
  /// milliseconds of CPU, which would otherwise hold up the DAP traffic.
  Future<void> seed(Map<String, String> files) async {
    if (_customReader) {
      for (final MapEntry(key: path, value: key) in files.entries) {
        await hasChanged(path, key: key);
      }
      return;
    }
    final paths = files.keys.toList();
    final maxBytes = _maxBytes;
    final hashes = await Isolate.run(() => _hashAll(paths, maxBytes));
    for (var i = 0; i < paths.length; i++) {
      _store(files[paths[i]]!, hashes[i]);
    }
  }

  /// SHA-256 of the current content without storing it; null when the file
  /// is missing, unreadable or larger than the limit (unknown).
  Future<String?> digest(String path) async {
    try {
      final bytes = await _readFile(path);
      if (bytes == null || bytes.length > _maxBytes) return null;
      return sha256.convert(bytes).toString();
    } on Object {
      return null;
    }
  }

  /// Forgets the stored hash, so the next event for the file counts as a
  /// change again (used when a reload failed).
  void forget(String key) => _hashes.remove(key);

  void _store(String key, String value) {
    _hashes.remove(key); // keep insertion order = recency
    _hashes[key] = value;
    while (_hashes.length > maxEntries) {
      _hashes.remove(_hashes.keys.first);
    }
  }

  Future<List<int>?> _readLimited(String path) async {
    final file = File(path);
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.openRead(0, _maxBytes + 1)) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on FileSystemException {
      return null;
    }
  }
}

/// What [ContentHashTracker.hasChanged] would store for each of [paths].
/// Runs on a background isolate, so it reads synchronously.
List<String> _hashAll(List<String> paths, int maxBytes) => [
  for (final path in paths) _hashFile(path, maxBytes),
];

String _hashFile(String path, int maxBytes) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final bytes = file.readSync(maxBytes + 1);
    if (bytes.length > maxBytes) return ContentHashTracker._tooBig;
    return sha256.convert(bytes).toString();
  } on FileSystemException {
    return ContentHashTracker._deleted;
  } finally {
    file?.closeSync();
  }
}
