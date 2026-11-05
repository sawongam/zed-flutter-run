/// DevTools pages that `flutter_run devtools [page]` can open.
enum DevToolsPage {
  inspector('inspector'),
  performance('performance'),
  cpuProfiler('cpu-profiler'),
  memory('memory'),
  network('network'),
  logging('logging');

  const DevToolsPage(this.route);

  /// The path segment below `/devtools/`.
  final String route;

  /// Parses a user-supplied page name (case-insensitive). Accepts
  /// `cpu-profiler`, `cpu_profiler` and `cpuprofiler`. Null if unknown.
  static DevToolsPage? parse(String name) {
    final key = name.trim().toLowerCase().replaceAll(RegExp(r'[-_]'), '');
    for (final page in values) {
      if (page.route.replaceAll('-', '') == key) return page;
    }
    return null;
  }

  /// All accepted route names, for help and error text.
  static String get names => values.map((p) => p.route).join(', ');
}
