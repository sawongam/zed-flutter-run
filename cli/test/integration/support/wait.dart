import 'dart:async';

import 'package:test/test.dart';

/// Repeatedly calls [probe] until it returns a non-null value.
///
/// Only for conditions that have no event to wait on (files appearing, a
/// process disappearing). Fails with [what] and the optional [context] text.
Future<T> pollFor<T extends Object>(
  FutureOr<T?> Function() probe, {
  required Duration timeout,
  required String what,
  Duration interval = const Duration(milliseconds: 100),
  String Function()? context,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final value = await probe();
    if (value != null) return value;
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'Timed out after ${timeout.inSeconds} s waiting for $what.'
        '${context == null ? '' : '\n${context()}'}',
      );
    }
    await Future<void>.delayed(interval);
  }
}

/// A bounded "nothing happens" window: fails as soon as [happened] returns
/// true, otherwise returns after [window]. These are the only places where the
/// suite lets real time pass.
Future<void> expectQuiet(
  bool Function() happened,
  Duration window, {
  required String what,
  String Function()? context,
}) async {
  final end = DateTime.now().add(window);
  while (DateTime.now().isBefore(end)) {
    if (happened()) {
      fail('Unexpected: $what.${context == null ? '' : '\n${context()}'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (happened()) fail('Unexpected: $what.');
}

/// Awaits [future] with a timeout that fails the test with [what].
Future<T> within<T>(
  Future<T> future,
  Duration timeout,
  String what, {
  String Function()? context,
}) {
  return future.timeout(
    timeout,
    onTimeout: () => fail(
      'Timed out after ${timeout.inSeconds} s waiting for $what.'
      '${context == null ? '' : '\n${context()}'}',
    ),
  );
}
