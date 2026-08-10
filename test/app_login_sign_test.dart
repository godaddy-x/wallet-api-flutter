import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:test/test.dart';
import 'package:wallet_api/src/client/config.dart';
import 'package:wallet_api/src/client/socket.dart';

void main() {
  test('createAppLoginRequest HMAC matches JS/Python (data=appKey, key=nonce+time+source)', () {
    final cfg = SdkConfig(
      appID: 'app-1',
      appKey: utf8.encode('0123456789abcdef').map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
    final req = createAppLoginRequest(cfg);
    final appKey = Uint8List.fromList(utf8.encode('0123456789abcdef'));
    final keyMaterial = utf8.encode('${req['nonce']}${req['time']}${req['source']}');
    final expected = base64Encode(
      crypto_pkg.Hmac(crypto_pkg.sha256, keyMaterial).convert(appKey).bytes,
    );
    expect(req['sign'], expected);
    expect(req['appID'], 'app-1');
    expect(req['source'], 'API');
  });
}
