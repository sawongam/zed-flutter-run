import 'dart:io';

/// Where process signals come from, injected so that tests raise them by hand.
abstract interface class SignalSource {
  /// Events of [signal]; throws when the platform cannot watch it.
  Stream<ProcessSignal> watch(ProcessSignal signal);
}

/// The real signals of this process.
class SystemSignalSource implements SignalSource {
  const SystemSignalSource();

  @override
  Stream<ProcessSignal> watch(ProcessSignal signal) => signal.watch();
}
