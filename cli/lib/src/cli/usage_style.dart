import '../common/style.dart';

final RegExp _heading = RegExp(r'^[A-Z][A-Za-z ]*:$');
final RegExp _option = RegExp(r'^(\s*)(-\S.*?)(\s{2,}\S.*)?$');
final RegExp _entry = RegExp(r'^(  )(\S+)( {2,}.*)$');

/// Colours the usage text that `package:args` builds: section headings,
/// flags, command names and exit codes. The text itself is not changed, so a
/// plain [style] returns it as it is.
String styleUsage(String usage, Style style) {
  if (!style.enabled) return usage;
  var section = '';
  return usage
      .split('\n')
      .map((line) {
        if (_heading.hasMatch(line)) {
          section = line;
          return style.heading(line);
        }
        if (line.startsWith('Usage: ')) {
          section = 'Usage:';
          return '${style.heading('Usage:')} '
              '${style.bold(line.substring('Usage: '.length))}';
        }
        if (line.startsWith('Run "')) return style.dim(line);
        final option = _option.firstMatch(line);
        if (option != null) {
          return '${option[1]}${style.cyan(option[2]!)}${option[3] ?? ''}';
        }
        // Wrapped description lines start with a single space or deep
        // indentation, so `_entry` only matches the name column.
        final entry = _entry.firstMatch(line);
        if (entry != null &&
            (section == 'Available commands:' || section == 'Exit codes:')) {
          return '${entry[1]}${style.cyan(entry[2]!)}${entry[3]}';
        }
        return line;
      })
      .join('\n');
}
