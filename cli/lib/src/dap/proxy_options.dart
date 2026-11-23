import 'launch_rewriter.dart';

/// Every fixed wait of the proxy's start-up and shutdown paths, in one place.
/// The defaults are the production values; tests shrink them.
class ProxyTimings {
  const ProxyTimings({
    this.stoppingNoticeAfter = const Duration(seconds: 1),
    this.drainWait = const Duration(seconds: 2),
    this.snapshotWait = const Duration(seconds: 3),
    this.firstSnapshotDelay = const Duration(milliseconds: 300),
    this.disconnectGrace = const Duration(milliseconds: 500),
    this.adapterExitGrace = const Duration(milliseconds: 800),
    this.sweepGrace = const Duration(milliseconds: 300),
    this.hookWait = const Duration(seconds: 2),
    this.sweepWait = const Duration(seconds: 3),
    this.sweepWaitLate = const Duration(seconds: 1),
  });

  /// After a `terminate` this long without a result, say "Stopping the app".
  final Duration stoppingNoticeAfter;

  /// How long to wait for the adapter's last messages after it exited.
  final Duration drainWait;

  /// Upper bound for reading the adapter's process tree.
  final Duration snapshotWait;

  /// Delay before the first periodic descendant snapshot.
  final Duration firstSnapshotDelay;

  /// After the adapter answered `disconnect`, how long it may take to exit
  /// before the editor gets its answer anyway.
  final Duration disconnectGrace;

  /// How long the adapter may exit on its own once the app was stopped.
  final Duration adapterExitGrace;

  /// Pause before sweeping descendants that are already exiting.
  final Duration sweepGrace;

  /// Upper bound for each owner hook and for flushing the editor channel.
  final Duration hookWait;

  /// Upper bound for killing the adapter's process tree.
  final Duration sweepWait;

  /// The same bound once the terminate deadline already passed.
  final Duration sweepWaitLate;
}

class ProxyOptions {
  const ProxyOptions({
    required this.kind,
    this.terminateTimeout = const Duration(seconds: 5),
    this.exitWait = const Duration(seconds: 5),
    this.initializeTimeout = const Duration(seconds: 120),
    this.initializeNoticeAfter = const Duration(seconds: 10),
    this.snapshotInterval = const Duration(seconds: 2),
    this.stableSnapshotInterval = const Duration(seconds: 20),
    this.timings = const ProxyTimings(),
  });

  final DapKind kind;

  /// Upper bound for the adapter to finish a `terminate` (also used for the
  /// injected one).
  final Duration terminateTimeout;

  /// Upper bound for the adapter to exit after `disconnect`.
  final Duration exitWait;

  /// Upper bound for the adapter's answer to `initialize`.
  final Duration initializeTimeout;

  /// After this long without an `initialize` answer, one notice says that
  /// Flutter is still starting.
  final Duration initializeNoticeAfter;

  /// How often the adapter's descendants are recorded while its process tree
  /// changes (reading the process table is slower on Windows, so the caller
  /// may raise this).
  final Duration snapshotInterval;

  /// The poll interval once the tree looked the same a few times in a row.
  /// The snapshots only matter for cleaning up after a crash, and process
  /// activity (a new isolate, the VM service coming up) still takes one at
  /// once, so a settled session needs no fast polling.
  final Duration stableSnapshotInterval;

  /// The remaining fixed waits.
  final ProxyTimings timings;
}
