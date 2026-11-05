# dart_console fixture

Contract used by the integration tests:

- `bin/main.dart` has exactly one line ending in `// BREAKPOINT_TARGET`; tests
  scan for the marker instead of hard-coding a line number.
- At that line the locals `total`, `i` and `n` are in scope. On the first hit
  `i == 0`, `n == 1` and `total == 0`.
- The program prints `TOTAL: 30` (sum of squares of 1..4) and exits 0.
