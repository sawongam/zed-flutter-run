import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Remembers the SHA-256 of each file's last seen content. There is no
/// baseline scan (ADR 0006): the first event for a file counts as a change.
class ContentHashTracker {
  ContentHashTracker({
    Future<List<int>?> Function(String path)? readFile,
    int maxBytes = 2 * 1024 * 1024,
    int maxEntries = 5000,
  }) : _maxBytes = maxBytes,
       _maxEntries = maxEntries {
    _readFile = readFile ?? _readLimited;
  }

  final int _maxBytes;
  final int _maxEntries;
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
    while (_hashes.length > _maxEntries) {
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
