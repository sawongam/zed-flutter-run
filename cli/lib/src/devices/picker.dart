import '../common/console.dart';
import '../common/errors.dart';

/// Shows a numbered list and reads a choice with plain line input.
///
/// Accepts the item number, an exact id (when [idOf] is given), `r` (rescan,
/// when [rescan] is given), and `q` or an empty line to cancel (returns null).
/// End of input also cancels. After [maxAttempts] invalid answers a
/// [UsageError] is thrown. Rescanning does not count as an invalid answer.
Future<T?> pickFromList<T>(
  List<T> items,
  String Function(T) label,
  Console console, {
  String? savedId,
  String Function(T)? idOf,
  Future<List<T>> Function()? rescan,
  int maxAttempts = 3,
}) async {
  var current = List<T>.of(items);
  var invalid = 0;
  var showList = true;

  while (true) {
    if (showList) {
      if (current.isEmpty) {
        console.out('There is nothing to choose from.');
      }
      for (var i = 0; i < current.length; i++) {
        final saved =
            savedId != null && idOf != null && idOf(current[i]) == savedId;
        console.out(
          '  ${(i + 1).toString().padLeft(2)}) ${label(current[i])}'
          '${saved ? ' (saved)' : ''}',
        );
      }
      showList = false;
    }
    console.out(
      'Enter a number${idOf != null ? ' or an id' : ''}'
      '${rescan != null ? ', r to scan again' : ''}, or q to cancel:',
    );
    final line = (await console.readLine())?.trim();
    if (line == null || line.isEmpty || line.toLowerCase() == 'q') {
      return null;
    }
    if (rescan != null && line.toLowerCase() == 'r') {
      current = await rescan();
      showList = true;
      continue;
    }
    final n = int.tryParse(line);
    if (n != null && n >= 1 && n <= current.length) return current[n - 1];
    if (idOf != null) {
      for (final item in current) {
        if (idOf(item) == line) return item;
      }
    }
    invalid++;
    if (invalid >= maxAttempts) {
      throw const UsageError(
        'No valid choice was entered.',
        hint: 'Run the command again and enter one of the listed numbers.',
      );
    }
    console.out('"$line" is not one of the choices. Please try again.');
  }
}
