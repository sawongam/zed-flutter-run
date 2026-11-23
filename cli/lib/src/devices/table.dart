/// Lines of a plain-text table: every column but the last is padded to its
/// widest cell, and columns are two spaces apart. The first row is the
/// header.
List<String> formatTable(List<List<String>> rows) {
  final columns = rows.first.length;
  final widths = List<int>.filled(columns, 0);
  for (final row in rows) {
    for (var i = 0; i < columns; i++) {
      if (row[i].length > widths[i]) widths[i] = row[i].length;
    }
  }
  return [
    for (final row in rows)
      [
        for (var i = 0; i < columns; i++)
          i == columns - 1 ? row[i] : row[i].padRight(widths[i]),
      ].join('  ').trimRight(),
  ];
}
