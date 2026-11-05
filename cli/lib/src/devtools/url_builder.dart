import 'pages.dart';

/// Normalises a VM service address to `ws://H:P/TOKEN=/ws`.
///
/// Accepts `ws://H:P/TOKEN=/ws`, `http://H:P/TOKEN=/` and `http://H:P/TOKEN=`
/// (also `wss`/`https` and a token-less `ws://H:P/ws`). Throws
/// [FormatException] when the input has no host, no port or another scheme.
String normalizeWsUri(String vmServiceUri) {
  final input = vmServiceUri.trim();
  final Uri uri;
  try {
    uri = Uri.parse(input);
  } on FormatException {
    throw FormatException('Not a valid VM service address.', input);
  }
  const schemes = {'ws', 'wss', 'http', 'https'};
  if (!schemes.contains(uri.scheme) ||
      uri.host.isEmpty ||
      !_hasExplicitPort(input)) {
    throw FormatException(
      'Expected an address like ws://127.0.0.1:1234/TOKEN=/ws.',
      input,
    );
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  while (segments.isNotEmpty && segments.last == 'ws') {
    segments.removeLast();
  }
  final secure = uri.scheme == 'wss' || uri.scheme == 'https';
  final path = [...segments, 'ws'].join('/');
  return '${secure ? 'wss' : 'ws'}://${_authority(uri)}/$path';
}

// `Uri.hasPort` is false for an explicit default port such as http `:80`.
bool _hasExplicitPort(String input) =>
    RegExp(r'^[a-zA-Z]+://[^/?#]*:\d+(?:[/?#]|$)').hasMatch(input);

String _authority(Uri uri) {
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return '$host:${uri.port}';
}

/// Builds `http://H:P/TOKEN=/devtools/<route>?uri=<percent-encoded ws URI>`,
/// the URL under which the Dart Development Service serves DevTools.
Uri buildDdsDevToolsUrl(String vmServiceUri, DevToolsPage page) {
  final ws = Uri.parse(normalizeWsUri(vmServiceUri));
  final segments = ws.pathSegments.where((s) => s.isNotEmpty).toList()
    ..removeLast(); // the trailing 'ws'
  final secure = ws.scheme == 'wss';
  return Uri(
    scheme: secure ? 'https' : 'http',
    host: ws.host,
    port: ws.port,
    pathSegments: [...segments, 'devtools', page.route],
    query: 'uri=${Uri.encodeQueryComponent(ws.toString())}',
  );
}

/// True only for http(s) URLs to the local machine (`127.0.0.1`, `localhost`,
/// `::1`) without credentials. Anything else is never handed to a browser.
bool isSafeBrowserUrl(Uri url) {
  if (url.scheme != 'http' && url.scheme != 'https') return false;
  if (url.userInfo.isNotEmpty) return false;
  final host = url.host.toLowerCase();
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}
