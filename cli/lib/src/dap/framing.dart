import 'dart:convert';
import 'dart:typed_data';

import 'messages.dart';

/// The byte stream is not valid DAP framing (missing or invalid
/// `Content-Length`, oversized header, or a body that is not a JSON object).
class DapFramingException implements Exception {
  DapFramingException(this.message);

  final String message;

  @override
  String toString() => 'DapFramingException: $message';
}

/// Incremental decoder for `Content-Length` framed DAP messages.
///
/// Handles partial headers and bodies, many messages per chunk, multi-byte
/// UTF-8 split across chunks, extra headers and header-name case.
class DapFrameDecoder {
  static const int maxHeaderBytes = 8192;
  static const int maxBodyBytes = 64 * 1024 * 1024;

  Uint8List _buf = Uint8List(4096);
  int _start = 0;
  int _end = 0;
  int? _bodyLength;

  /// Adds [chunk] and returns every message that is now complete.
  List<DapJson> add(List<int> chunk) {
    _append(chunk);
    final out = <DapJson>[];
    int? searchFrom = (_end - chunk.length - 3).clamp(_start, _end).toInt();
    while (true) {
      if (_bodyLength == null) {
        final headerEnd = _findHeaderEnd(searchFrom ?? _start);
        searchFrom = null;
        if (headerEnd < 0) {
          if (_end - _start > maxHeaderBytes) {
            throw DapFramingException(
              'Header block larger than $maxHeaderBytes bytes without a '
              'blank line.',
            );
          }
          break;
        }
        final header = latin1.decode(
          Uint8List.sublistView(_buf, _start, headerEnd),
        );
        _bodyLength = _parseContentLength(header);
        _start = headerEnd + 4;
      }
      final length = _bodyLength!;
      if (_end - _start < length) break;
      final bodyBytes = Uint8List.sublistView(_buf, _start, _start + length);
      _start += length;
      _bodyLength = null;
      out.add(_decodeBody(bodyBytes));
    }
    _compact();
    return out;
  }

  void _append(List<int> chunk) {
    if (chunk.isEmpty) return;
    final needed = _end + chunk.length;
    if (needed > _buf.length) {
      final live = _end - _start;
      var capacity = _buf.length;
      while (capacity < live + chunk.length) {
        capacity *= 2;
      }
      final next = Uint8List(capacity)..setRange(0, live, _buf, _start);
      _buf = next;
      _start = 0;
      _end = live;
    }
    _buf.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  void _compact() {
    if (_start == _end) {
      _start = 0;
      _end = 0;
      if (_buf.length > 1024 * 1024) _buf = Uint8List(4096);
    } else if (_start > 0 && _start >= _buf.length ~/ 2) {
      final live = _end - _start;
      _buf.setRange(0, live, _buf, _start);
      _start = 0;
      _end = live;
    }
  }

  int _findHeaderEnd(int from) {
    for (var i = from; i + 3 < _end; i++) {
      if (_buf[i] == 13 &&
          _buf[i + 1] == 10 &&
          _buf[i + 2] == 13 &&
          _buf[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static int _parseContentLength(String header) {
    for (final line in header.split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      if (line.substring(0, colon).trim().toLowerCase() != 'content-length') {
        continue;
      }
      final value = line.substring(colon + 1).trim();
      if (!RegExp(r'^\d{1,10}$').hasMatch(value)) {
        throw DapFramingException('Invalid Content-Length "$value".');
      }
      final length = int.parse(value);
      if (length > maxBodyBytes) {
        throw DapFramingException(
          'Content-Length $length is larger than the ${maxBodyBytes ~/ (1024 * 1024)} MiB limit for one message.',
        );
      }
      return length;
    }
    throw DapFramingException('Missing Content-Length header.');
  }

  static DapJson _decodeBody(Uint8List bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw DapFramingException('Body is not valid UTF-8 JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw DapFramingException('Body is not a JSON object.');
    }
    return decoded;
  }
}

/// Encodes [message] as `Content-Length: N\r\n\r\n` + UTF-8 JSON.
List<int> encodeDapMessage(DapJson message) {
  final body = utf8.encode(jsonEncode(message));
  final head = ascii.encode('Content-Length: ${body.length}\r\n\r\n');
  return Uint8List(head.length + body.length)
    ..setRange(0, head.length, head)
    ..setRange(head.length, head.length + body.length, body);
}
