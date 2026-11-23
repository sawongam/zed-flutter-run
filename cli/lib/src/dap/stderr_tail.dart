/// The last few lines the adapter wrote to stderr, for error messages.
class StderrTail {
  StderrTail({this.maxLines = 20});

  final int maxLines;
  final List<String> _lines = [];

  void add(String line) {
    _lines.add(line);
    if (_lines.length > maxLines) _lines.removeAt(0);
  }

  /// The most recent line, or null.
  String? get last => _lines.isEmpty ? null : _lines.last;

  /// All kept lines, joined with newlines.
  String get text => _lines.join('\n');
}
