import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;

import 'canonical.dart';

Future<Uint8List> aesGcmEncryptBase(
  Uint8List plaintext,
  Uint8List key,
  Uint8List aad,
) async {
  if (key.length != 32) {
    throw ArgumentError('key must be 32 bytes for AES-256');
  }
  final algorithm = cryptography.AesGcm.with256bits();
  final nonce = getRandomSecure(12);
  final secretBox = await algorithm.encrypt(
    plaintext,
    secretKey: cryptography.SecretKey(key),
    nonce: nonce,
    aad: aad,
  );
  final out = Uint8List(nonce.length + secretBox.cipherText.length + secretBox.mac.bytes.length);
  out.setRange(0, 12, nonce);
  out.setRange(12, 12 + secretBox.cipherText.length, secretBox.cipherText);
  out.setRange(
    12 + secretBox.cipherText.length,
    out.length,
    secretBox.mac.bytes,
  );
  return out;
}

Future<Uint8List> aesGcmDecryptBase(
  Uint8List encrypted,
  Uint8List key,
  Uint8List aad,
) async {
  if (key.length != 32) {
    throw ArgumentError('key must be 32 bytes for AES-256');
  }
  if (encrypted.length < 28) {
    throw StateError('encrypted payload too short');
  }
  final nonce = encrypted.sublist(0, 12);
  final cipherAndTag = encrypted.sublist(12);
  final mac = cryptography.Mac(cipherAndTag.sublist(cipherAndTag.length - 16));
  final cipherText = cipherAndTag.sublist(0, cipherAndTag.length - 16);
  final algorithm = cryptography.AesGcm.with256bits();
  return Uint8List.fromList(
    await algorithm.decrypt(
      cryptography.SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: cryptography.SecretKey(key),
      aad: aad,
    ),
  );
}

Future<String> aesGcmEncryptBase64(
  Uint8List plaintext,
  Uint8List key,
  Uint8List aad,
) async {
  return base64Encode(await aesGcmEncryptBase(plaintext, key, aad));
}

Future<Uint8List> aesGcmDecryptBase64(
  String encryptedB64,
  Uint8List key,
  Uint8List aad,
) async {
  return aesGcmDecryptBase(base64Decode(encryptedB64), key, aad);
}
