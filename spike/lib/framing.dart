import 'dart:convert';
import 'dart:typed_data';

/// Accumulates bytes and yields complete DAP messages (Content-Length framed).
class DapDecoder {
  final List<int> _buf = [];

  List<Map<String, dynamic>> add(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <Map<String, dynamic>>[];
    while (true) {
      final headerEnd = _find(const [13, 10, 13, 10]);
      if (headerEnd < 0) break;
      final header = ascii.decode(_buf.sublist(0, headerEnd));
      final m = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false)
          .firstMatch(header);
      if (m == null) throw FormatException('No Content-Length in "$header"');
      final len = int.parse(m.group(1)!);
      final start = headerEnd + 4;
      if (_buf.length < start + len) break;
      final body = utf8.decode(_buf.sublist(start, start + len));
      _buf.removeRange(0, start + len);
      out.add(jsonDecode(body) as Map<String, dynamic>);
    }
    return out;
  }

  int _find(List<int> pat) {
    for (var i = 0; i + pat.length <= _buf.length; i++) {
      var ok = true;
      for (var j = 0; j < pat.length; j++) {
        if (_buf[i + j] != pat[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }
}

Uint8List encodeDap(Map<String, dynamic> msg) {
  final body = utf8.encode(jsonEncode(msg));
  final head = ascii.encode('Content-Length: ${body.length}\r\n\r\n');
  return Uint8List.fromList([...head, ...body]);
}
