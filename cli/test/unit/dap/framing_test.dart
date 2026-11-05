import 'dart:convert';

import 'package:flutter_run/src/dap/framing.dart';
import 'package:flutter_run/src/dap/messages.dart';
import 'package:test/test.dart';

List<int> frame(Object message, {String extraHeaders = ''}) {
  final body = utf8.encode(jsonEncode(message));
  return [
    ...ascii.encode('Content-Length: ${body.length}\r\n$extraHeaders\r\n'),
    ...body,
  ];
}

void main() {
  group('DapFrameDecoder', () {
    test('decodes a message fed one byte at a time', () {
      final decoder = DapFrameDecoder();
      final out = <DapJson>[];
      for (final byte in frame({'seq': 1, 'type': 'request', 'command': 'x'})) {
        out.addAll(decoder.add([byte]));
      }
      expect(out, [
        {'seq': 1, 'type': 'request', 'command': 'x'},
      ]);
    });

    test('decodes three messages in one chunk', () {
      final bytes = [
        ...frame({'seq': 1}),
        ...frame({'seq': 2}),
        ...frame({'seq': 3}),
      ];
      expect(DapFrameDecoder().add(bytes).map((m) => m['seq']), [1, 2, 3]);
    });

    test('keeps a trailing partial message for the next chunk', () {
      final decoder = DapFrameDecoder();
      final bytes = [
        ...frame({'seq': 1}),
        ...frame({'seq': 2}),
      ];
      final cut = bytes.length - 5;
      expect(decoder.add(bytes.sublist(0, cut)).map((m) => m['seq']), [1]);
      expect(decoder.add(bytes.sublist(cut)).map((m) => m['seq']), [2]);
    });

    test('multi-byte UTF-8 split across chunks round trips', () {
      final message = {'text': 'héllo \u{1F600} 日本語'};
      final bytes = frame(message);
      for (var cut = 1; cut < bytes.length; cut++) {
        final decoder = DapFrameDecoder();
        final out = [
          ...decoder.add(bytes.sublist(0, cut)),
          ...decoder.add(bytes.sublist(cut)),
        ];
        expect(out, [message], reason: 'cut at $cut');
      }
    });

    test('tolerates extra headers and header name case', () {
      final body = utf8.encode('{"seq":9}');
      final bytes = [
        ...ascii.encode(
          'X-Other: 1\r\ncontent-LENGTH:   ${body.length}\r\n'
          'Content-Type: application/json\r\n\r\n',
        ),
        ...body,
      ];
      expect(DapFrameDecoder().add(bytes), [
        {'seq': 9},
      ]);
    });

    test('throws on a missing Content-Length', () {
      expect(
        () => DapFrameDecoder().add(ascii.encode('X-Other: 1\r\n\r\n{}')),
        throwsA(isA<DapFramingException>()),
      );
    });

    test('throws on an invalid Content-Length', () {
      for (final value in ['abc', '-5', '1x', '']) {
        expect(
          () => DapFrameDecoder().add(
            ascii.encode('Content-Length: $value\r\n\r\n{}'),
          ),
          throwsA(isA<DapFramingException>()),
          reason: value,
        );
      }
    });

    test('throws on a body that is not a JSON object', () {
      expect(
        () =>
            DapFrameDecoder().add(ascii.encode('Content-Length: 2\r\n\r\n[]')),
        throwsA(isA<DapFramingException>()),
      );
      expect(
        () =>
            DapFrameDecoder().add(ascii.encode('Content-Length: 3\r\n\r\n{x}')),
        throwsA(isA<DapFramingException>()),
      );
    });

    test('throws on an endless header', () {
      expect(
        () => DapFrameDecoder().add(List.filled(10000, 65)),
        throwsA(isA<DapFramingException>()),
      );
    });

    test('handles a large body', () {
      final message = {'text': 'x' * 300000};
      final bytes = frame(message);
      final decoder = DapFrameDecoder();
      final out = <DapJson>[];
      for (var i = 0; i < bytes.length; i += 7001) {
        out.addAll(
          decoder.add(bytes.sublist(i, (i + 7001).clamp(0, bytes.length))),
        );
      }
      expect(out, [message]);
    });
  });

  test('C12: the buffer shrinks after a large message', () {
    final decoder = DapFrameDecoder();
    final big = {'text': 'x' * (2 * 1024 * 1024)};
    expect(decoder.add(frame(big)), [big]);
    expect(decoder.add(frame({'seq': 1})), [
      {'seq': 1},
    ]);
  });

  test('a header split exactly inside the terminator is found', () {
    final bytes = frame({'seq': 3});
    final decoder = DapFrameDecoder();
    final idx = latin1.decode(bytes).indexOf('\r\n\r\n') + 2;
    expect(decoder.add(bytes.sublist(0, idx)), isEmpty);
    expect(decoder.add(bytes.sublist(idx)), [
      {'seq': 3},
    ]);
  });

  test('S7: a body over 64 MiB is rejected with a clear message', () {
    expect(
      () => DapFrameDecoder().add(
        ascii.encode('Content-Length: ${64 * 1024 * 1024 + 1}\r\n\r\n'),
      ),
      throwsA(
        isA<DapFramingException>().having(
          (e) => e.message,
          'message',
          contains('64 MiB'),
        ),
      ),
    );
  });

  group('encodeDapMessage', () {
    test('writes a valid frame with the byte length of the UTF-8 body', () {
      final message = {'seq': 1, 'text': 'é日'};
      final bytes = encodeDapMessage(message);
      final text = latin1.decode(bytes);
      final bodyLength = utf8.encode(jsonEncode(message)).length;
      expect(text, startsWith('Content-Length: $bodyLength\r\n\r\n'));
      expect(DapFrameDecoder().add(bytes), [message]);
    });
  });

  group('messages', () {
    test('predicates', () {
      expect(isRequest({'type': 'request'}), isTrue);
      expect(isResponse({'type': 'response'}), isTrue);
      expect(isEvent({'type': 'event'}), isTrue);
      expect(isEvent({'type': 'request'}), isFalse);
    });

    test('makeResponse and makeOutputEvent', () {
      expect(
        makeResponse(
          requestSeq: 3,
          command: 'initialize',
          success: false,
          message: 'no',
          seq: 7,
        ),
        {
          'seq': 7,
          'type': 'response',
          'request_seq': 3,
          'success': false,
          'command': 'initialize',
          'message': 'no',
        },
      );
      expect(makeOutputEvent('hi\n', seq: 8), {
        'seq': 8,
        'type': 'event',
        'event': 'output',
        'body': {'category': 'console', 'output': 'hi\n'},
      });
      expect(makeOutputEvent('e', category: 'stderr', seq: 9)['body'], {
        'category': 'stderr',
        'output': 'e',
      });
    });
  });
}
