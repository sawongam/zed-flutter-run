enum NoticeLevel { info, warn, error }

const String _reset = '\x1b[0m';

/// Formats a console notice for a DAP `output` event.
///
/// Each line gets the `[flutter_run]` prefix; warning and error notices carry
/// the words `Warning:` / `Error:` on the first line so colour is never the
/// only signal. The result ends with exactly one newline.
String formatNotice(String text, NoticeLevel level) {
  final color = switch (level) {
    NoticeLevel.info => '\x1b[36m',
    NoticeLevel.warn => '\x1b[33m',
    NoticeLevel.error => '\x1b[31m',
  };
  final label = switch (level) {
    NoticeLevel.info => '',
    NoticeLevel.warn => 'Warning: ',
    NoticeLevel.error => 'Error: ',
  };
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceFirst(RegExp(r'\n+$'), '')
      .split('\n');
  final out = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    out
      ..write(color)
      ..write('[flutter_run] ')
      ..write(i == 0 ? label : '')
      ..write(lines[i])
      ..write(_reset)
      ..write('\n');
  }
  return out.toString();
}
