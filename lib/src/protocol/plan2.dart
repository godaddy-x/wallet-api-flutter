import 'dart:convert';
import 'dart:typed_data';

import '../crypto/aes_gcm.dart';
import '../crypto/canonical.dart';
import '../crypto/mldsa87.dart';
import 'envelope.dart';

String plan2BodyHmac({
  required String router,
  required String data,
  required String nonce,
  required int ts,
  required int plan,
  required int usr,
  required Uint8List sharedKey,
}) {
  final digest = signBodyMessage(router, data, nonce, ts, plan, usr, sharedKey);
  return base64Encode(digest);
}

String plan2OuterSign({
  required String router,
  required String data,
  required String nonce,
  required int ts,
  required int plan,
  required int usr,
  required String clientPrivateKey,
}) {
  final digest = digestBodyMessage(router, data, nonce, ts, plan, usr);
  return signWithPrivateKeyB64(digest, clientPrivateKey);
}

Future<JsonBody> buildPlan2JsonBody({
  required String router,
  required int plan,
  required int usr,
  required String clientPrk,
  required Uint8List sharedKey,
  required Uint8List plaintext,
  bool plan2KeyBootstrap = false,
}) async {
  final jsonBody = JsonBody(
    d: '',
    n: getMessageNonce(),
    s: '',
    r: router,
    t: unixSecond(),
    p: plan,
    u: usr,
  );
  final aad = appendBodyMessage(jsonBody.r, '', jsonBody.n, jsonBody.t, jsonBody.p, jsonBody.u);
  final key = sharedKey.length > 32 ? sharedKey.sublist(0, 32) : sharedKey;
  jsonBody.d = await aesGcmEncryptBase64(plaintext, key, aad);
  jsonBody.s = plan2BodyHmac(
    router: jsonBody.r,
    data: jsonBody.d,
    nonce: jsonBody.n,
    ts: jsonBody.t,
    plan: jsonBody.p,
    usr: jsonBody.u,
    sharedKey: sharedKey,
  );
  if (jsonBodyRequiresOuterSignature(plan, plan2KeyBootstrap: plan2KeyBootstrap)) {
    jsonBody.e = plan2OuterSign(
      router: jsonBody.r,
      data: jsonBody.d,
      nonce: jsonBody.n,
      ts: jsonBody.t,
      plan: jsonBody.p,
      usr: jsonBody.u,
      clientPrivateKey: clientPrk,
    );
  }
  return jsonBody;
}

JsonBody buildPlan2KeyRequestJsonBody({
  required String router,
  required int usr,
  required String clientPrk,
  required Map<String, dynamic> payload,
}) {
  final jsonBody = JsonBody(
    d: base64Encode(utf8.encode(jsonEncode(payload))),
    n: getMessageNonce(),
    s: '',
    r: router,
    t: unixSecond(),
    p: 0,
    u: usr,
  );
  jsonBody.s = plan2BodyHmac(
    router: jsonBody.r,
    data: jsonBody.d,
    nonce: jsonBody.n,
    ts: jsonBody.t,
    plan: jsonBody.p,
    usr: jsonBody.u,
    sharedKey: Uint8List(0),
  );
  jsonBody.e = plan2OuterSign(
    router: jsonBody.r,
    data: jsonBody.d,
    nonce: jsonBody.n,
    ts: jsonBody.t,
    plan: jsonBody.p,
    usr: jsonBody.u,
    clientPrivateKey: clientPrk,
  );
  return jsonBody;
}

Future<JsonBody> buildPlan2EncryptedJsonBody({
  required String router,
  required int usr,
  required String clientPrk,
  required Uint8List sharedKey,
  required Object requestObj,
}) {
  final plaintext = utf8.encode(jsonEncode(requestObj));
  return buildPlan2JsonBody(
    router: router,
    plan: 2,
    usr: usr,
    clientPrk: clientPrk,
    sharedKey: sharedKey,
    plaintext: Uint8List.fromList(plaintext),
  );
}

void verifyPlan2ResponseTime(int ts) {
  if (ts <= 0 || (unixSecond() - ts).abs() > 300) {
    throw StateError('response time invalid');
  }
}

void verifyPlan2ResponseHmac({
  required String router,
  required JsonResp resp,
  required int usr,
  required Uint8List sharedKey,
}) {
  final expected = plan2BodyHmac(
    router: router,
    data: resp.d,
    nonce: resp.n,
    ts: resp.t,
    plan: resp.p,
    usr: usr,
    sharedKey: sharedKey,
  );
  if (!compareBase64Sign(base64Decode(expected), resp.s)) {
    throw StateError('plan2 response signature verification failed');
  }
}

void verifyPlan2ResponseOuterSign({
  required String router,
  required JsonResp resp,
  required int usr,
  required String serverPublicKey,
}) {
  if (!planRequiresOuterSignature(resp.p)) return;
  if (resp.e == null || resp.e!.isEmpty) {
    throw StateError('response outer signature missing');
  }
  final digest = digestBodyMessage(router, resp.d, resp.n, resp.t, resp.p, usr);
  if (!verifyWithPublicKeyB64(digest, resp.e!, serverPublicKey)) {
    throw StateError('response ML-DSA sign verify invalid');
  }
}

Future<Uint8List> decryptPlan2Response({
  required String router,
  required JsonResp resp,
  required int usr,
  required Uint8List sharedKey,
}) async {
  if (resp.p == 1 || resp.p == 2) {
    final aad = appendBodyMessage(router, '', resp.n, resp.t, resp.p, usr);
    final key = sharedKey.length > 32 ? sharedKey.sublist(0, 32) : sharedKey;
    return aesGcmDecryptBase64(resp.d, key, aad);
  }
  return base64Decode(resp.d);
}

String stringifyPublicKeyPayload(Map<String, dynamic> payload) => jsonEncode(payload);
