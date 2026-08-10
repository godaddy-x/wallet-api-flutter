import 'dart:convert';
import 'dart:typed_data';

import 'package:pqcrypto/pqcrypto.dart';

import 'canonical.dart';

const int mldsa87PubLen = 2592;
const int mldsa87SeedLen = 32;
const int mldsa87SigLen = 4627;

final DilithiumParams _mldsa87 = DilithiumParams.mlDsa87;
final Map<String, Uint8List> _expandedSkCache = {};

void validateMldsa87PublicKeyBytes(Uint8List publicKey) {
  if (publicKey.length != mldsa87PubLen) {
    throw ArgumentError(
      'Invalid ML-DSA-87 public key length: expected $mldsa87PubLen bytes, got ${publicKey.length}',
    );
  }
}

Uint8List expandedSecretKeyFromPrivateKeyB64(String privateKeyB64) {
  final cached = _expandedSkCache[privateKeyB64];
  if (cached != null) return cached;

  final raw = base64Decode(privateKeyB64);
  late final Uint8List sk;
  if (raw.length == mldsa87SeedLen) {
    sk = MlDsa.generateKeyPairSeeded(_mldsa87, raw).$2;
  } else if (raw.length == _mldsa87.secretKeyBytes) {
    sk = raw;
  } else {
    throw ArgumentError(
      'Invalid ML-DSA-87 private key length: expected $mldsa87SeedLen-byte seed or '
      '${_mldsa87.secretKeyBytes}-byte expanded key, got ${raw.length}',
    );
  }
  _expandedSkCache[privateKeyB64] = sk;
  return sk;
}

({String publicKeyB64, String privateKeyB64}) generateUserMldsaKeyPair() {
  final seed = getRandomSecure(mldsa87SeedLen);
  final (pk, _) = MlDsa.generateKeyPairSeeded(_mldsa87, seed);
  validateMldsa87PublicKeyBytes(pk);
  return (
    publicKeyB64: base64Encode(pk),
    privateKeyB64: base64Encode(seed),
  );
}

String signWithPrivateKeyB64(Uint8List message, String privateKeyB64) {
  if (message.isEmpty) {
    throw ArgumentError('message cannot be empty');
  }
  final sk = expandedSecretKeyFromPrivateKeyB64(privateKeyB64);
  final sig = MlDsa.sign(sk, message, _mldsa87);
  if (sig.length != mldsa87SigLen) {
    throw StateError('unexpected ML-DSA-87 signature length: ${sig.length}');
  }
  return base64Encode(sig);
}

bool verifyWithPublicKeyB64(
  Uint8List message,
  String signatureB64,
  String publicKeyB64,
) {
  if (message.isEmpty) {
    throw ArgumentError('message cannot be empty');
  }
  final pk = base64Decode(publicKeyB64);
  validateMldsa87PublicKeyBytes(pk);
  final sig = base64Decode(signatureB64);
  if (sig.length != mldsa87SigLen) {
    throw ArgumentError(
      'Invalid ML-DSA-87 signature length: expected $mldsa87SigLen bytes, got ${sig.length}',
    );
  }
  return MlDsa.verify(pk, message, sig, _mldsa87);
}

void clearMldsaKeyCache() => _expandedSkCache.clear();
