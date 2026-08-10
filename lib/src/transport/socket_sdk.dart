import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/aes_gcm.dart';
import '../crypto/canonical.dart';
import '../crypto/mlkem1024.dart';
import '../protocol/envelope.dart';
import '../protocol/plan2.dart';
import '../protocol/public_key.dart';
import 'ws_connect.dart';

class SocketSdkOptions {
  SocketSdkOptions({
    required this.domain,
    required this.clientNo,
    required this.clientPrk,
    required this.serverPub,
    this.ssl = false,
    this.wsPath = '/ws',
    this.language = 'en-US',
    this.healthPingSec = 10,
  });

  final String domain;
  final int clientNo;
  final String clientPrk;
  final String serverPub;
  final bool ssl;
  final String wsPath;
  final String language;
  final int healthPingSec;
}

typedef TokenRefreshCallback = Future<AuthToken?> Function();

/// Long-lived OPS/MPC WebSocket client (Plan2 login + Plan1 business).
class SocketSDK {
  SocketSDK(SocketSdkOptions options)
      : domain = options.domain,
        clientNo = options.clientNo,
        clientPrk = options.clientPrk,
        serverPub = options.serverPub,
        ssl = options.ssl,
        language = options.language,
        healthPingSec = options.healthPingSec,
        _wsPath = options.wsPath.startsWith('/') ? options.wsPath : '/${options.wsPath}';

  final String domain;
  final int clientNo;
  final String clientPrk;
  final String serverPub;
  final bool ssl;
  final String language;
  final int healthPingSec;

  String _wsPath;
  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _recvSub;
  bool _connected = false;
  bool _connecting = false;
  bool _closed = false;
  AuthToken? _auth;
  String _rawAuthHeader = '';
  bool _reconnectEnabled = false;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _tokenMonitorTimer;
  TokenRefreshCallback? _tokenRefreshCallback;
  final Map<String, Completer<JsonResp>> _pending = {};
  final _sendLock = _AsyncLock();

  void authToken(AuthToken token) {
    _auth = token;
    _rawAuthHeader = '';
  }

  AuthToken? getAuth() => _auth;

  bool validToken() {
    final auth = _auth;
    if (auth == null || auth.token.isEmpty || auth.secret.isEmpty) return false;
    return unixSecond() < auth.expired;
  }

  bool isWebSocketConnected() => _connected && _ws != null;

  void enableReconnect() => _reconnectEnabled = true;

  void setTokenExpiredCallback(TokenRefreshCallback callback) {
    _tokenRefreshCallback = callback;
  }

  void setWebSocketPath(String path) {
    _wsPath = path.startsWith('/') ? path : '/$path';
  }

  String _uri() {
    final scheme = ssl ? 'wss' : 'ws';
    return '$scheme://$domain$_wsPath';
  }

  Uint8List _tokenSecretBytes() {
    final auth = _auth;
    if (auth == null || auth.secret.isEmpty) {
      throw StateError('token secret missing');
    }
    final secret = base64Decode(auth.secret);
    if (secret.isEmpty) throw StateError('token secret invalid');
    return secret;
  }

  Future<void> connectWebSocketWithRawAuth(String path, String authHeader) async {
    if (authHeader.isEmpty) throw ArgumentError('authorization header is empty');
    _rawAuthHeader = authHeader;
    setWebSocketPath(path);
    await connectWebSocket();
  }

  Future<void> connectWebSocket() async {
    if (_connecting) throw StateError('connection already in progress');
    if (isWebSocketConnected()) return;
    if (!validToken() && _rawAuthHeader.isEmpty) {
      final cb = _tokenRefreshCallback;
      if (cb != null) {
        final refreshed = await cb();
        if (refreshed != null) authToken(refreshed);
      }
    }
    if (!validToken() && _rawAuthHeader.isEmpty) {
      throw StateError('token empty or token expired, and raw authorization is empty');
    }

    _connecting = true;
    try {
      await _openSocket();
      if (validToken()) {
        await _sendAuthHandshake();
      }
      _connected = true;
      _startHeartbeat();
      _startTokenMonitor();
    } catch (_) {
      _connected = false;
      if (_reconnectEnabled) {
        _scheduleReconnect();
        return;
      }
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  Future<void> disconnectWebSocket() async {
    _closed = true;
    _connected = false;
    _stopHeartbeat();
    _stopTokenMonitor();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _recvSub?.cancel();
    _recvSub = null;
    await _ws?.sink.close();
    _ws = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('WebSocket disconnected'));
      }
    }
    _pending.clear();
  }

  Future<void> _openSocket() async {
    final authHeader = validToken() ? _auth!.token : _rawAuthHeader;
    _ws = await connectPlan2Ws(
      url: _uri(),
      authorization: authHeader,
      language: language,
      timeout: const Duration(seconds: 15),
    );
    _recvSub = _ws!.stream.listen(
      _onMessage,
      onError: (_) => _handleClose(),
      onDone: () => _handleClose(),
      cancelOnError: false,
    );
  }

  void _onMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final resp = JsonResp.fromJson(data);
      if (resp.n.isEmpty) return;
      final authKey = 'auth_${resp.n}';
      final pending = _pending.remove(resp.n) ??
          _pending.remove(authKey) ??
          (resp.r != null ? _pending.remove(resp.r) : null);
      if (pending != null && !pending.isCompleted) {
        pending.complete(resp);
      }
    } catch (_) {
      // ignore malformed frames
    }
  }

  Future<void> _handleClose() async {
    _connected = false;
    _ws = null;
    _stopHeartbeat();
    if (_reconnectEnabled && !_closed) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_reconnectTimer != null) return;
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      _reconnectTimer = null;
      try {
        await connectWebSocket();
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  Future<void> _sendPayload(String payload) async {
    final ws = _ws;
    if (ws == null) throw StateError('WebSocket not connected');
    await _sendLock.synchronized(() async {
      ws.sink.add(payload);
    });
  }

  Future<JsonResp?> _writeBody(JsonBody body, bool waitResponse, int timeoutSec) async {
    if (_ws == null) throw StateError('WebSocket not connected');
    final payload = jsonEncode(body.toJson());
    if (waitResponse) {
      final completer = Completer<JsonResp>();
      _pending[body.n] = completer;
      await _sendPayload(payload);
      try {
        return await completer.future.timeout(Duration(seconds: timeoutSec < 1 ? 1 : timeoutSec));
      } on TimeoutException {
        _pending.remove(body.n);
        throw TimeoutException(
          'wait response timeout (nonce=${body.n}, timeout=${timeoutSec}s)',
        );
      }
    }
    await _sendPayload(payload);
    return null;
  }

  Future<JsonResp?> sendWebSocketRawBody(JsonBody body, bool waitResponse, int timeoutSec) {
    return _writeBody(body, waitResponse, timeoutSec);
  }

  Future<String> _buildPlan2BootstrapAuthorization() async {
    final pub = createPublicKeyPayload(
      key: base64Encode(getRandomSecure(32)),
      tag: base64Encode(getRandomSecure(32)),
      usr: clientNo,
      clientPrivateKey: clientPrk,
    );
    return base64Encode(utf8.encode(stringifyPublicKeyPayload(pub)));
  }

  Future<({String authorization, Uint8List sharedKey})> getWebSocketPlan2Auth(
    String keyRouter,
    int timeoutSec,
  ) async {
    final reqPublic = createPublicKeyPayload(
      key: base64Encode(getRandomSecure(32)),
      tag: base64Encode(getRandomSecure(32)),
      usr: clientNo,
      clientPrivateKey: clientPrk,
    );
    final jsonBody = buildPlan2KeyRequestJsonBody(
      router: keyRouter,
      usr: clientNo,
      clientPrk: clientPrk,
      payload: reqPublic,
    );
    final resp = await sendWebSocketRawBody(jsonBody, true, timeoutSec);
    if (resp == null) throw StateError('plan2 key response is nil');
    if (resp.c != 200) throw StateError(resp.m ?? 'plan2 key failed');
    verifyPlan2ResponseTime(resp.t);
    verifyPlan2ResponseHmac(
      router: keyRouter,
      resp: resp,
      usr: clientNo,
      sharedKey: Uint8List(0),
    );
    verifyPlan2ResponseOuterSign(
      router: keyRouter,
      resp: resp,
      usr: clientNo,
      serverPublicKey: serverPub,
    );

    final serverPubMap = jsonDecode(utf8.decode(base64Decode(resp.d))) as Map<String, dynamic>;
    checkPublicKey(serverPubMap, serverPub);
    final encap = encapsulateToPeer(serverPubMap['key'] as String);
    final sharedKey = await deriveNegotiatedKey(encap.sharedSecret, serverPubMap['noc'] as String);
    final authPub = createPublicKeyPayload(
      key: serverPubMap['key'] as String,
      tag: encap.kemCtB64,
      usr: clientNo,
      clientPrivateKey: clientPrk,
    );
    final authHeader = base64Encode(utf8.encode(stringifyPublicKeyPayload(authPub)));
    return (authorization: authHeader, sharedKey: sharedKey);
  }

  Future<dynamic> sendWebSocketPlan2Message(
    String router,
    Object requestObj,
    Uint8List sharedKey,
    int timeoutSec,
  ) async {
    final jsonBody = await buildPlan2EncryptedJsonBody(
      router: router,
      usr: clientNo,
      clientPrk: clientPrk,
      sharedKey: sharedKey,
      requestObj: requestObj,
    );
    final resp = await sendWebSocketRawBody(jsonBody, true, timeoutSec);
    if (resp == null) throw StateError('plan2 response is nil');
    if (resp.c != 200) throw StateError(resp.m ?? 'plan2 request failed');
    verifyPlan2ResponseTime(resp.t);
    verifyPlan2ResponseHmac(
      router: router,
      resp: resp,
      usr: clientNo,
      sharedKey: sharedKey,
    );
    verifyPlan2ResponseOuterSign(
      router: router,
      resp: resp,
      usr: clientNo,
      serverPublicKey: serverPub,
    );
    final decrypted = await decryptPlan2Response(
      router: router,
      resp: resp,
      usr: clientNo,
      sharedKey: sharedKey,
    );
    if (decrypted.isEmpty) throw StateError('response data is empty');
    return jsonDecode(utf8.decode(decrypted));
  }

  Future<AuthToken> loginByWebSocketPlan2Auto(
    String keyRouter,
    String loginRouter,
    Object requestObj,
    int timeoutSec,
  ) async {
    final bootstrapAuth = await _buildPlan2BootstrapAuthorization();
    await disconnectWebSocket();
    _closed = false;
    await connectWebSocketWithRawAuth(_wsPath, bootstrapAuth);

    final plan2 = await getWebSocketPlan2Auth(keyRouter, timeoutSec);
    await disconnectWebSocket();
    _closed = false;
    await connectWebSocketWithRawAuth(_wsPath, plan2.authorization);

    final tokenData = await sendWebSocketPlan2Message(
      loginRouter,
      requestObj,
      plan2.sharedKey,
      timeoutSec,
    ) as Map<String, dynamic>;
    final token = AuthToken.fromJson(tokenData);
    authToken(token);
    _rawAuthHeader = '';
    return token;
  }

  Future<dynamic> sendWebSocketMessage(
    String router,
    Object requestObj, {
    bool waitResponse = true,
    bool encryptRequest = true,
    int timeoutSec = 300,
  }) async {
    final jsonBody = JsonBody(
      d: '',
      n: getMessageNonce(),
      s: '',
      r: router,
      t: unixSecond(),
      p: encryptRequest ? 1 : 0,
      u: clientNo,
    );
    final secret = _tokenSecretBytes();
    final jsonData = utf8.encode(jsonEncode(requestObj));
    if (jsonBody.p == 1) {
      final aad = appendBodyMessage(jsonBody.r, '', jsonBody.n, jsonBody.t, jsonBody.p, jsonBody.u);
      final key = secret.length > 32 ? secret.sublist(0, 32) : secret;
      jsonBody.d = await aesGcmEncryptBase64(Uint8List.fromList(jsonData), key, aad);
    } else {
      jsonBody.d = base64Encode(jsonData);
    }
    jsonBody.s = base64Encode(
      signBodyMessage(
        jsonBody.r,
        jsonBody.d,
        jsonBody.n,
        jsonBody.t,
        jsonBody.p,
        jsonBody.u,
        secret,
      ),
    );

    final resp = await sendWebSocketRawBody(jsonBody, waitResponse, timeoutSec);
    if (!waitResponse) return null;
    if (resp == null) throw StateError('response is nil');
    return _verifyWebSocketResponse(router, resp);
  }

  Future<dynamic> _verifyWebSocketResponse(String router, JsonResp resp) async {
    if (resp.c != 200) {
      throw StateError(resp.m ?? 'response error (code=${resp.c})');
    }
    verifyResponseTime(resp.t);
    final secret = _tokenSecretBytes();
    final expected = signBodyMessage(router, resp.d, resp.n, resp.t, resp.p, clientNo, secret);
    if (!compareBase64Sign(expected, resp.s)) {
      throw StateError('response signature verification failed');
    }
    if (planRequiresOuterSignature(resp.p)) {
      verifyPlan2ResponseOuterSign(
        router: router,
        resp: resp,
        usr: clientNo,
        serverPublicKey: serverPub,
      );
    }
    late final Uint8List decrypted;
    if (resp.p == 1) {
      final aad = appendBodyMessage(router, '', resp.n, resp.t, resp.p, clientNo);
      final key = secret.length > 32 ? secret.sublist(0, 32) : secret;
      decrypted = await aesGcmDecryptBase64(resp.d, key, aad);
    } else {
      decrypted = base64Decode(resp.d);
    }
    return jsonDecode(utf8.decode(decrypted));
  }

  Future<void> _sendAuthHandshake() async {
    final path = _wsPath;
    final jsonBody = JsonBody(
      d: '',
      n: getMessageNonce(),
      s: '',
      r: path,
      t: unixSecond(),
      p: 1,
      u: clientNo,
    );
    final secret = _tokenSecretBytes();
    final payload = utf8.encode(jsonEncode('auth_handshake'));
    final aad = appendBodyMessage(jsonBody.r, '', jsonBody.n, jsonBody.t, jsonBody.p, jsonBody.u);
    final key = secret.length > 32 ? secret.sublist(0, 32) : secret;
    jsonBody.d = await aesGcmEncryptBase64(Uint8List.fromList(payload), key, aad);
    jsonBody.s = base64Encode(
      signBodyMessage(
        jsonBody.r,
        jsonBody.d,
        jsonBody.n,
        jsonBody.t,
        jsonBody.p,
        jsonBody.u,
        secret,
      ),
    );

    final authKey = 'auth_${jsonBody.n}';
    final completer = Completer<JsonResp>();
    _pending[authKey] = completer;
    await _sendPayload(jsonEncode(jsonBody.toJson()));
    try {
      final resp = await completer.future.timeout(const Duration(seconds: 5));
      await _verifyWebSocketResponse(path, resp);
    } on TimeoutException {
      _pending.remove(authKey);
      throw TimeoutException('handshake timeout');
    }
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    final interval = Duration(seconds: healthPingSec.clamp(1, 15));
    _heartbeatTimer = Timer.periodic(interval, (_) async {
      if (!isWebSocketConnected()) return;
      if (_rawAuthHeader.isNotEmpty && !validToken()) return;
      try {
        await _sendHeartbeat();
      } catch (_) {
        await _handleClose();
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _sendHeartbeat() async {
    final secret = _tokenSecretBytes();
    final jsonBody = JsonBody(
      d: base64Encode(utf8.encode(jsonEncode('ping'))),
      n: getMessageNonce(),
      s: '',
      r: '/ws/ping',
      t: unixSecond(),
      p: 0,
      u: clientNo,
    );
    jsonBody.s = base64Encode(
      signBodyMessage(
        jsonBody.r,
        jsonBody.d,
        jsonBody.n,
        jsonBody.t,
        jsonBody.p,
        jsonBody.u,
        secret,
      ),
    );
    await _writeBody(jsonBody, false, 0);
  }

  void _startTokenMonitor() {
    _stopTokenMonitor();
    _tokenMonitorTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_rawAuthHeader.isNotEmpty) return;
      if (!validToken() && !isWebSocketConnected()) {
        final cb = _tokenRefreshCallback;
        if (cb != null) {
          final token = await cb();
          if (token != null) authToken(token);
        }
      }
    });
  }

  void _stopTokenMonitor() {
    _tokenMonitorTimer?.cancel();
    _tokenMonitorTimer = null;
  }
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
