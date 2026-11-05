// Usage: dart run bin/reload.dart --session-file <p> [reload|restart|status]
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final i = args.indexOf('--session-file');
  final sf = i >= 0 ? args[i + 1] : null;
  final rest = [for (var j = 0; j < args.length; j++) if (j != i && j != i + 1) args[j]];
  final cmd = rest.isEmpty ? 'reload' : rest.first;
  if (sf == null) {
    stderr.writeln('missing --session-file');
    exit(2);
  }
  final s = jsonDecode(File(sf).readAsStringSync()) as Map<String, dynamic>;
  final sock = await Socket.connect('127.0.0.1', s['port'] as int);
  sock.writeln(jsonEncode({'token': s['token'], 'command': cmd}));
  final line = await utf8.decoder
      .bind(sock)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 90));
  print(line);
  await sock.close();
  exit((jsonDecode(line) as Map)['ok'] == true ? 0 : 1);
}
