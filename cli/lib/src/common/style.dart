/// ANSI text styling that does nothing when colour is off, so callers never
/// have to check first.
class Style {
  const Style(this.enabled);

  /// A style that returns text unchanged.
  static const Style plain = Style(false);

  final bool enabled;

  String bold(String s) => _wrap(s, '1');
  String dim(String s) => _wrap(s, '2');
  String red(String s) => _wrap(s, '31');
  String green(String s) => _wrap(s, '32');
  String yellow(String s) => _wrap(s, '33');
  String cyan(String s) => _wrap(s, '36');

  /// A heading: bold and cyan.
  String heading(String s) => _wrap(s, '1;36');

  /// Bold red, for the word "error".
  String error(String s) => _wrap(s, '1;31');

  String _wrap(String s, String code) =>
      enabled && s.isNotEmpty ? '\x1B[${code}m$s\x1B[0m' : s;
}

/// Decides whether a stream gets colour. `NO_COLOR` (any value) and
/// `TERM=dumb` turn it off, `FORCE_COLOR` turns it on for a pipe, and
/// otherwise only a terminal gets colour.
bool colorWanted({
  required bool isTerminal,
  required Map<String, String> environment,
}) {
  final noColor = environment['NO_COLOR'];
  if (noColor != null && noColor.isNotEmpty) return false;
  final force = environment['FORCE_COLOR'];
  if (force != null && force.isNotEmpty && force != '0') return true;
  if (environment['TERM'] == 'dumb') return false;
  return isTerminal;
}
