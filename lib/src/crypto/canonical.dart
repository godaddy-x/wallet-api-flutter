import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_pkg;

const sep = '|';

int unixSecond() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List getRandomSecure(int length) {
  final rnd = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => rnd.nextInt(256)));
}

/// Message nonce as 32 hex chars (16 bytes), matching Python/JS SDKs.
String getMessageNonce() {
  final bytes = getRandomSecure(16);
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List appendBodyMessage(
  String path,
  String data,
  String nonce,
  int time,
  int plan,
  int user,
) {
  return utf8.encode('$path$sep$data$sep$nonce$sep$time$sep$plan$sep$user');
}

Uint8List hmacSha256(Uint8List data, Uint8List key) {
  final hmac = crypto_pkg.Hmac(crypto_pkg.sha256, key);
  return Uint8List.fromList(hmac.convert(data).bytes);
}

Uint8List digestBodyMessage(
  String path,
  String data,
  String nonce,
  int time,
  int plan,
  int user,
) {
  return Uint8List.fromList(
    crypto_pkg.sha256.convert(appendBodyMessage(path, data, nonce, time, plan, user)).bytes,
  );
}

Uint8List signBodyMessage(
  String path,
  String data,
  String nonce,
  int time,
  int plan,
  int user,
  Uint8List key,
) {
  return hmacSha256(appendBodyMessage(path, data, nonce, time, plan, user), key);
}

bool compareBase64Sign(Uint8List expected, String actualB64) {
  try {
    final actual = base64Decode(actualB64);
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ actual[i];
    }
    return diff == 0;
  } catch (_) {
    return false;
  }
}
