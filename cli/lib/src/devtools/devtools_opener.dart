import '../common/errors.dart';
import '../common/logger.dart';
import 'browser_opener.dart';
import 'pages.dart';
import 'url_builder.dart';

/// The browser could not be opened; [url] is still valid and should be shown.
class DevToolsOpenException extends ExternalToolException {
  DevToolsOpenException(this.url, String reason, {super.cause})
    : super(
        'DevTools could not be opened automatically ($reason). '
        'Open this address yourself: $url',
      );

  final Uri url;
}

/// Opens [page] for [vmServiceUri] in the browser and returns the URL.
/// Does nothing but return the URL when [isDartSession] is true.
/// On a launch failure throws [DevToolsOpenException], which carries the URL.
Future<Uri> openDevToolsOnce(
  String vmServiceUri,
  DevToolsPage page,
  BrowserOpener opener, {
  Logger? logger,
  bool isDartSession = false,
}) async {
  final log = logger ?? Logger.silent();
  final Uri url;
  try {
    url = buildDdsDevToolsUrl(vmServiceUri, page);
  } on FormatException catch (e) {
    throw SessionRequestException(
      'The app reported an address that DevTools cannot use: ${e.message}',
    );
  }
  if (isDartSession) {
    // The Dart debug adapter's DDS does not serve DevTools; opening would 404.
    log.debug('Not opening DevTools for a Dart session: $url');
    return url;
  }
  log.debug('Opening DevTools ${page.route}: $url');
  try {
    await opener.open(url);
  } on FlutterRunException catch (e) {
    throw DevToolsOpenException(url, e.message, cause: e);
  }
  return url;
}
