import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<WebSocketChannel> connectPlan2Ws({
  required String url,
  required String authorization,
  required String language,
  required Duration timeout,
}) async {
  final channel = IOWebSocketChannel.connect(
    Uri.parse(url),
    headers: {
      'Authorization': authorization,
      'Language': language,
    },
    connectTimeout: timeout,
  );
  await channel.ready.timeout(timeout);
  return channel;
}
