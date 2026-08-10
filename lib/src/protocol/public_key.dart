import 'dart:convert';

import '../crypto/canonical.dart';
import '../crypto/mldsa87.dart';

const fiveMinutes = 300;

Map<String, dynamic> createPublicKeyPayload({
  required String key,
  required String tag,
  required int usr,
  required String clientPrivateKey,
}) {
  final exp = unixSecond();
  final noc = base64Encode(getRandomSecure(32));
  final signData = utf8.encode('$key$sep$tag$sep$noc$sep$exp$sep$usr');
  final sig = signWithPrivateKeyB64(signData, clientPrivateKey);
  return {
    'key': key,
    'tag': tag,
    'noc': noc,
    'exp': exp,
    'usr': usr,
    'sig': sig,
  };
}

void checkPublicKey(Map<String, dynamic> payload, String serverPublicKey) {
  final key = payload['key']?.toString() ?? '';
  final tag = payload['tag']?.toString() ?? '';
  final sig = payload['sig']?.toString() ?? '';
  final noc = payload['noc']?.toString() ?? '';
  final usr = (payload['usr'] as num?)?.toInt() ?? -1;
  final exp = (payload['exp'] as num?)?.toInt() ?? 0;

  if (key.length < 32) throw StateError('request key invalid');
  if (tag.length < 32) throw StateError('request tag invalid');
  if (sig.length < 600) throw StateError('request sig invalid');
  if (noc.length < 32) throw StateError('request noc invalid');
  if (usr < 0) throw StateError('request usr invalid');
  if ((unixSecond() - exp).abs() > fiveMinutes) {
    throw StateError('request exp invalid');
  }
  final signData = utf8.encode('$key$sep$tag$sep$noc$sep$exp$sep$usr');
  if (!verifyWithPublicKeyB64(signData, sig, serverPublicKey)) {
    throw StateError('request signature invalid');
  }
}

void verifyResponseTime(int ts) {
  if (ts <= 0 || (unixSecond() - ts).abs() > fiveMinutes) {
    throw StateError('response time invalid');
  }
}
