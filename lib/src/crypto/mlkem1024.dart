import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:pqcrypto/pqcrypto.dart';

const int mlkem1024EncapKeyLen = 1568;
const int mlkem1024CiphertextLen = 1568;
const int mlkem1024SharedSecretLen = 32;
const _sharedInfo = 'freego-ecdh-aes-gcm';

final KyberKem _mlkem1024 = PqcKem.kyber1024;

({Uint8List sharedSecret, String kemCtB64}) encapsulateToPeer(String serverEncapKeyB64) {
  final ek = base64Decode(serverEncapKeyB64);
  if (ek.length != mlkem1024EncapKeyLen) {
    throw ArgumentError(
      'Invalid ML-KEM-1024 encapsulation key: expected $mlkem1024EncapKeyLen bytes, got ${ek.length}',
    );
  }
  final (ct, ss) = _mlkem1024.encapsulate(ek);
  if (ct.length != mlkem1024CiphertextLen) {
    throw StateError('unexpected ML-KEM ciphertext length: ${ct.length}');
  }
  if (ss.length != mlkem1024SharedSecretLen) {
    throw StateError('unexpected ML-KEM shared secret length: ${ss.length}');
  }
  return (
    sharedSecret: ss,
    kemCtB64: base64Encode(ct),
  );
}

Future<Uint8List> deriveNegotiatedKey(Uint8List sharedSecret, String nocB64) async {
  final salt = nocB64.isEmpty ? Uint8List(0) : base64Decode(nocB64);
  final hkdf = cryptography.Hkdf(
    hmac: cryptography.Hmac.sha256(),
    outputLength: 32,
  );
  final key = await hkdf.deriveKey(
    secretKey: cryptography.SecretKey(sharedSecret),
    nonce: salt,
    info: utf8.encode(_sharedInfo),
  );
  return Uint8List.fromList(await key.extractBytes());
}
