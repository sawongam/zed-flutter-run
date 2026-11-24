import '../common/style.dart';

/// Lines of a plain-text table: every column but the last is padded to its
/// widest cell, and columns are two spaces apart. The first row is the
/// header.
///
/// With a [style] that has colour on, the header is bold. Padding is done
/// before styling so the escape codes do not break the alignment.
List<String> formatTable(List<List<String>> rows, {Style style = Style.plain}) {
  final columns = rows.first.length;
  final widths = List<int>.filled(columns, 0);
  for (final row in rows) {
    for (var i = 0; i < columns; i++) {
      if (row[i].length > widths[i]) widths[i] = row[i].length;
    }
  }
  String line(List<String> row) => [
    for (var i = 0; i < columns; i++)
      i == columns - 1 ? row[i] : row[i].padRight(widths[i]),
  ].join('  ').trimRight();
  return [
    for (var r = 0; r < rows.length; r++)
      r == 0 ? style.bold(line(rows[r])) : line(rows[r]),
  ];
}
