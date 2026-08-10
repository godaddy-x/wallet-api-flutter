import 'dart:convert';

import 'package:pqcrypto/pqcrypto.dart';
import 'package:test/test.dart';
import 'package:wallet_api/src/crypto/mldsa87.dart';
import 'package:wallet_api/src/crypto/mlkem1024.dart';

void main() {
  group('ML-DSA-87 / ML-KEM-1024', () {
    test('user keypair uses 32-byte seed and 2592-byte public key', () {
      final keys = generateUserMldsaKeyPair();
      expect(base64Decode(keys.publicKeyB64).length, mldsa87PubLen);
      expect(base64Decode(keys.privateKeyB64).length, mldsa87SeedLen);
    });

    test('seed-based sign and verify round-trip', () {
      final keys = generateUserMldsaKeyPair();
      final message = utf8.encode('path|data|nonce|time|plan|user');
      final sigB64 = signWithPrivateKeyB64(message, keys.privateKeyB64);
      expect(base64Decode(sigB64).length, mldsa87SigLen);
      expect(
        verifyWithPublicKeyB64(message, sigB64, keys.publicKeyB64),
        isTrue,
      );
    });

    test('ML-KEM-1024 encapsulate output sizes', () {
      final kem = PqcKem.kyber1024;
      final (pk, _) = kem.generateKeyPair();
      expect(pk.length, mlkem1024EncapKeyLen);
      final result = encapsulateToPeer(base64Encode(pk));
      expect(result.sharedSecret.length, mlkem1024SharedSecretLen);
      expect(base64Decode(result.kemCtB64).length, mlkem1024CiphertextLen);
    });
  });
}
