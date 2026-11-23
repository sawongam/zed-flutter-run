import 'dart:convert';

/// [text] with comments and trailing commas blanked out by spaces, so every
/// character keeps its offset. Zed settings, Zed keymaps and VS Code's
/// `launch.json` are all JSON with comments, and edits to them must leave
/// the user's comments in place, which is why offsets matter.
String blankJsonc(String text, {bool trailingCommas = true}) {
  final out = StringBuffer();
  var i = 0;
  var inString = false;
  while (i < text.length) {
    final c = text[i];
    if (inString) {
      out.write(c);
      if (c == r'\' && i + 1 < text.length) {
        out.write(text[i + 1]);
        i += 2;
        continue;
      }
      if (c == '"') inString = false;
      i++;
      continue;
    }
    if (c == '"') {
      inString = true;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < text.length && text[i + 1] == '/') {
      while (i < text.length && text[i] != '\n') {
        out.write(text[i] == '\r' ? '\r' : ' ');
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < text.length && text[i + 1] == '*') {
      final end = text.indexOf('*/', i + 2);
      final stop = end < 0 ? text.length : end + 2;
      for (; i < stop; i++) {
        out.write(text[i] == '\n' || text[i] == '\r' ? text[i] : ' ');
      }
      continue;
    }
    out.write(c);
    i++;
  }
  final blanked = out.toString();
  return trailingCommas ? _blankTrailingCommas(blanked) : blanked;
}

String _blankTrailingCommas(String text) {
  final chars = text.split('');
  var inString = false;
  for (var i = 0; i < chars.length; i++) {
    final c = chars[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == ',') {
      var j = i + 1;
      while (j < chars.length && chars[j].trim().isEmpty) {
        j++;
      }
      if (j < chars.length && (chars[j] == ']' || chars[j] == '}')) {
        chars[i] = ' ';
      }
    }
  }
  return chars.join();
}

/// Decodes JSON that may have comments, trailing commas or a BOM.
/// Throws [FormatException] when it is not valid even then.
Object? decodeJsonc(String text) {
  final body = text.startsWith('﻿') ? text.substring(1) : text;
  return jsonDecode(blankJsonc(body));
}

/// [text] with [element] added as the last element of its top-level JSON
/// array, keeping comments and layout. Returns null when [text] is not a
/// JSON array.
String? appendToJsoncArray(String text, String element) {
  final bom = text.startsWith('﻿') ? '﻿' : '';
  final body = bom.isEmpty ? text : text.substring(1);
  final code = blankJsonc(body, trailingCommas: false);
  final close = code.trimRight().length - 1;
  if (close < 0 || code[close] != ']') return null;
  var last = close - 1;
  while (last >= 0 && code[last].trim().isEmpty) {
    last--;
  }
  if (last < 0) return null;
  final needsComma = code[last] != '[' && code[last] != ',';
  final indented = element
      .trimRight()
      .split('\n')
      .map((l) => l.isEmpty ? l : '  $l')
      .join('\n');
  final insertion = '${needsComma ? ',' : ''}\n$indented\n';
  // The rest keeps any comment after the last element and the closing
  // bracket; only the line break we replace is dropped.
  final rest = body
      .substring(last + 1)
      .replaceFirst(RegExp(r'^[ \t]*\r?\n'), '');
  return '$bom${body.substring(0, last + 1)}$insertion$rest';
}
