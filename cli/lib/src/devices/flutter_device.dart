import 'dart:convert';

import '../common/errors.dart';
import '../common/json_types.dart';

/// One entry of `flutter devices --machine`.
class FlutterDevice {
  const FlutterDevice({
    required this.id,
    required this.name,
    required this.platform,
    this.category,
    this.emulator = false,
    this.sdk,
    this.isSupported = true,
  });

  /// Reads one object of the machine output. `platform` comes from
  /// `targetPlatform`. Throws [FormatException] when `id` or `name` is missing.
  factory FlutterDevice.fromMachineJson(Json j) {
    final id = j['id'];
    final name = j['name'];
    if (id is! String || id.isEmpty || name is! String) {
      throw const FormatException('A device entry has no id or name.');
    }
    final platform = j['targetPlatform'] ?? j['platform'];
    return FlutterDevice(
      id: id,
      name: name,
      platform: platform is String ? platform : 'unknown',
      category: j['category'] is String ? j['category'] as String : null,
      emulator: j['emulator'] == true,
      sdk: j['sdk'] is String ? j['sdk'] as String : null,
      isSupported: j['isSupported'] != false,
    );
  }

  final String id;
  final String name;
  final String platform;
  final String? category;
  final String? sdk;
  final bool emulator;
  final bool isSupported;

  Json toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'platform': platform,
    'category': category,
    'emulator': emulator,
    'sdk': sdk,
    'isSupported': isSupported,
  };
}

/// Parses the stdout of `flutter devices --machine`. Anything before the JSON
/// array (banners such as the root-user warning, first-run messages) is
/// skipped. Throws [ExternalToolException] when no JSON array can be found.
List<FlutterDevice> parseDevicesMachineOutput(String stdout) {
  final decoded = decodeLeadingJsonArray(stdout);
  if (decoded == null) {
    throw const ExternalToolException(
      'Flutter printed a device list that could not be read.',
      hint: 'Run "flutter devices --machine" yourself to see what it prints.',
    );
  }
  final devices = <FlutterDevice>[];
  for (final entry in decoded) {
    if (entry is! Map<String, Object?>) continue;
    try {
      devices.add(FlutterDevice.fromMachineJson(entry));
    } on FormatException {
      // Entries without an id are of no use to us.
    }
  }
  return devices;
}

/// Finds the first JSON array in [text], ignoring noise around it.
List<Object?>? decodeLeadingJsonArray(String text) => _decodeArray(text);

List<Object?>? _decodeArray(String text) {
  final candidates = <int>[];
  for (var i = text.indexOf('['); i >= 0; i = text.indexOf('[', i + 1)) {
    candidates.add(i);
  }
  // Brackets at the start of a line first; bracketed noise ("[!] ...",
  // "note [1]") is tried afterwards.
  bool atLineStart(int i) => i == 0 || text[i - 1] == '\n';
  final ordered = [
    ...candidates.where(atLineStart),
    ...candidates.where((i) => !atLineStart(i)),
  ];
  List<Object?>? fallback;
  for (final from in ordered) {
    final end = _matchingBracket(text, from);
    if (end < 0) continue;
    try {
      final value = jsonDecode(text.substring(from, end + 1));
      if (value is! List<Object?>) continue;
      final looksLikeDevices =
          value.isEmpty ||
          value.every((e) => e is Map<String, Object?> && e['id'] is String);
      if (looksLikeDevices) return value;
      fallback ??= value;
    } on FormatException {
      // Try the next candidate.
    }
  }
  return fallback;
}

/// Index of the `]` that closes the `[` at [from], honouring JSON strings;
/// -1 when unbalanced.
int _matchingBracket(String text, int from) {
  var depth = 0;
  var inString = false;
  for (var i = from; i < text.length; i++) {
    final c = text[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
    } else if (c == '"') {
      inString = true;
    } else if (c == '[') {
      depth++;
    } else if (c == ']') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}
