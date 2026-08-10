import 'package:web_socket_channel/web_socket_channel.dart';

Future<WebSocketChannel> connectPlan2Ws({
  required String url,
  required String authorization,
  required String language,
  required Duration timeout,
}) {
  throw UnsupportedError(
    'wallet_api WebSocket transport requires dart:io (VM / mobile / desktop). '
    'Custom Authorization headers are not available on web.',
  );
}
