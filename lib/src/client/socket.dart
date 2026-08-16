import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/canonical.dart';
import '../protocol/envelope.dart';
import '../transport/socket_sdk.dart';
import 'client_no.dart';
import 'config.dart';

final _cliSignLock = _AsyncLock();

Map<String, dynamic> createAppLoginRequest(SdkConfig cfg) {
  final nonce = base64Encode(getRandomSecure(32));
  final time = unixSecond();
  const source = 'API';
  late final Uint8List appKey;
  try {
    appKey = Uint8List.fromList(_hexDecode(cfg.appKey));
  } catch (e) {
    throw ArgumentError('invalid appKey hex: $e');
  }
  if (appKey.isEmpty) {
    throw ArgumentError('invalid appKey hex');
  }
  // Server verifier: HMAC data=appKey, key=nonce+time+source.
  final sign = base64Encode(
    hmacSha256(appKey, utf8.encode('$nonce$time$source')),
  );
  return {
    'appID': cfg.appID,
    'nonce': nonce,
    'time': time,
    'source': source,
    'sign': sign,
  };
}

Map<String, dynamic> loginRequestForConfig(SdkConfig cfg) {
  if (cfg.appID.trim().isNotEmpty && cfg.appKey.trim().isNotEmpty) {
    return createAppLoginRequest(cfg);
  }
  final source = cfg.source.trim().isEmpty ? 'API' : cfg.source.trim();
  return {'source': source};
}

Future<AuthToken> loginSocket(SdkConfig cfg) {
  return _cliSignLock.synchronized(() async {
    final sdk = SocketSDK(
      SocketSdkOptions(
        domain: cfg.domain,
        clientNo: parseClientNo(cfg.clientNo),
        clientPrk: cfg.clientPrk,
        serverPub: cfg.serverPub,
        ssl: cfg.ssl,
      ),
    );
    try {
      final req = loginRequestForConfig(cfg);
      return await sdk.loginByWebSocketPlan2Auto(
        cfg.keyPath.isEmpty ? '/api/PublicKey' : cfg.keyPath,
        cfg.loginPath.isEmpty ? '/api/Login' : cfg.loginPath,
        req,
        10,
      );
    } finally {
      await sdk.disconnectWebSocket();
    }
  });
}

Future<SocketSDK> newLongLivedSocket(SdkConfig cfg) async {
  final sdk = SocketSDK(
    SocketSdkOptions(
      domain: cfg.domain,
      clientNo: parseClientNo(cfg.clientNo),
      clientPrk: cfg.clientPrk,
      serverPub: cfg.serverPub,
      ssl: cfg.ssl,
    ),
  );
  final token = await loginSocket(cfg);
  sdk.authToken(token);
  sdk.enableReconnect();
  await sdk.connectWebSocket();
  if (!sdk.isWebSocketConnected()) {
    await sdk.disconnectWebSocket();
    throw StateError('WebSocket initial connect failed');
  }
  return sdk;
}

/// C 端 App 用户：已持有 AppUserLogin 的 JWT，跳过 /api/Login（无 appKey）。
Future<SocketSDK> newLongLivedSocketWithAuth(
  SdkConfig cfg,
  AuthToken token, {
  OpsSessionExpiredHandler? onSessionExpired,
}) async {
  final sdk = SocketSDK(
    SocketSdkOptions(
      domain: cfg.domain,
      clientNo: parseClientNo(cfg.clientNo),
      clientPrk: cfg.clientPrk,
      serverPub: cfg.serverPub,
      ssl: cfg.ssl,
    ),
  );
  sdk.authToken(token);
  sdk.enableReconnect();
  if (onSessionExpired != null) {
    sdk.setOnSessionExpired(onSessionExpired);
  }
  await sdk.connectWebSocket();
  if (!sdk.isWebSocketConnected()) {
    await sdk.disconnectWebSocket();
    throw StateError('WebSocket initial connect failed');
  }
  return sdk;
}

Future<Map<String, dynamic>> signTransaction(
  SocketSDK sdk,
  Map<String, dynamic> req,
  int wsTimeoutSec,
) {
  return _cliSignLock.synchronized(() async {
    final res = await sdk.sendWebSocketMessage(
      '/api/SignTransaction',
      req,
      waitResponse: true,
      encryptRequest: true,
      timeoutSec: wsTimeoutSec,
    );
    if (res == null) throw StateError('SignTransaction: empty response');
    return Map<String, dynamic>.from(res as Map);
  });
}

List<int> _hexDecode(String hex) {
  final cleaned = hex.trim();
  if (cleaned.length.isOdd) {
    throw FormatException('odd hex length');
  }
  final out = <int>[];
  for (var i = 0; i < cleaned.length; i += 2) {
    out.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
  }
  return out;
}

class _AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    return previous.then((_) => action()).whenComplete(() {
      if (!gate.isCompleted) gate.complete();
    });
  }
}
