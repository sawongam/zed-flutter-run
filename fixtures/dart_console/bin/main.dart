// Fixture for flutter_run integration tests. See ../README.md for the contract.

int square(int n) {
  return n * n;
}

int computeTotal(List<int> values) {
  var total = 0;
  for (var i = 0; i < values.length; i++) {
    final n = values[i];
    total += n; // BREAKPOINT_TARGET
    total += square(n) - n;
  }
  return total;
}

void main() {
  final total = computeTotal([1, 2, 3, 4]);
  print('TOTAL: $total');
}
