import 'dart:convert';

import '../common/json_types.dart';

sealed class MergeResult {
  const MergeResult();
}

/// The file did not exist; [content] is the whole new file.
class MergeCreated extends MergeResult {
  const MergeCreated(this.content);
  final String content;
}

/// The file was strict JSON; [content] is the merged file. [added] entries
/// were appended and [kept] entries were already there.
class MergeUpdated extends MergeResult {
  const MergeUpdated(this.content, {required this.added, required this.kept});
  final String content;
  final int added, kept;
}

/// The file cannot be edited safely. [reason] is a phrase for use inside
/// parentheses; [snippet] holds the entries to paste by hand.
class MergeNeedsManual extends MergeResult {
  const MergeNeedsManual({required this.reason, required this.snippet});
  final String reason;
  final String snippet;
}

const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

/// 2-space indented JSON, LF, trailing newline.
String encodeJsonFile(Object? value) => '${_encoder.convert(value)}\n';

/// True when [text] parses as strict JSON (no comments, no trailing commas).
bool isStrictJson(String text) {
  try {
    jsonDecode(text);
    return true;
  } on FormatException {
    return false;
  }
}

/// Merges [additions] into the JSON array in [existingText], keyed by
/// `label`. Existing entries and their order are kept; only entries whose
/// label is missing are appended. `null` means the file does not exist.
MergeResult mergeLabeledArray(String? existingText, List<Json> additions) {
  final unique = <String, Json>{};
  for (final entry in additions) {
    final label = entry['label'];
    if (label is String) unique.putIfAbsent(label, () => entry);
  }
  final wanted = unique.values.toList();

  if (existingText == null) return MergeCreated(encodeJsonFile(wanted));

  final snippet = encodeJsonFile(wanted).trimRight();
  final text = existingText.startsWith('\uFEFF')
      ? existingText.substring(1)
      : existingText;
  if (text.trim().isEmpty) return MergeCreated(encodeJsonFile(wanted));
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    final looksLikeJsonc =
        text.contains('//') ||
        text.contains('/*') ||
        RegExp(r',\s*[\]}]').hasMatch(text);
    return MergeNeedsManual(
      reason: looksLikeJsonc
          ? 'it has comments or trailing commas'
          : 'it is not valid JSON',
      snippet: snippet,
    );
  }
  if (decoded is! List<Object?>) {
    return MergeNeedsManual(reason: 'it is not a JSON array', snippet: snippet);
  }

  final present = <String>{
    for (final e in decoded)
      if (e is Map<String, Object?> && e['label'] is String)
        e['label'] as String,
  };
  final missing = wanted.where((e) => !present.contains(e['label'])).toList();
  if (missing.isEmpty) {
    return MergeUpdated(
      existingText,
      added: 0,
      kept: wanted.length - missing.length,
    );
  }
  return MergeUpdated(
    encodeJsonFile(<Object?>[...decoded, ...missing]),
    added: missing.length,
    kept: wanted.length - missing.length,
  );
}
