/// A duration as plain words for a user-facing message.
String describeDuration(Duration d) => d.inSeconds >= 1
    ? '${d.inSeconds} seconds'
    : '${d.inMilliseconds} milliseconds';
