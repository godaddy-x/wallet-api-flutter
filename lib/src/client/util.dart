import 'dart:convert';
import 'dart:io';

import 'config.dart';

class WalletApiException implements Exception {
  WalletApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

final errNilRequest = WalletApiException('request is nil');

bool isNilRequest(Object? value) => value == null;

SdkConfig readSdkConfigFile(String path) {
  final raw = File(path).readAsStringSync();
  final data = jsonDecode(raw) as Map<String, dynamic>;

  Object? pick(String camel, String snake, [Object? defaultValue = '']) {
    if (data.containsKey(camel)) return data[camel];
    if (data.containsKey(snake)) return data[snake];
    return defaultValue;
  }

  var clientNo = pick('clientNo', 'client_no', 0);
  if (clientNo is String && RegExp(r'^\d+$').hasMatch(clientNo)) {
    clientNo = int.parse(clientNo);
  }

  return SdkConfig(
    domain: '${pick('domain', 'domain', '')}',
    keyPath: '${pick('keyPath', 'key_path', '/api/PublicKey')}',
    loginPath: '${pick('loginPath', 'login_path', '/api/Login')}',
    source: '${pick('source', 'source', '')}',
    appID: '${pick('appID', 'app_id', '')}',
    appKey: '${pick('appKey', 'app_key', '')}',
    clientPrk: '${pick('clientPrk', 'client_prk', '')}',
    serverPub: '${pick('serverPub', 'server_pub', '')}',
    clientNo: clientNo is int ? clientNo : int.tryParse('$clientNo') ?? 0,
    ssl: pick('ssl', 'ssl', false) == true,
  );
}

bool sdkConfigEnabled(SdkConfig? cfg) =>
    cfg != null && cfg.domain.trim().isNotEmpty;

void normalizeConfig(Config cfg) {
  if (cfg.appKey.trim().isEmpty && cfg.ops != null && cfg.ops!.appKey.trim().isNotEmpty) {
    cfg.appKey = cfg.ops!.appKey;
  }
  if (cfg.appKey.trim().isEmpty) return;
  if (cfg.ops != null && cfg.ops!.appKey.trim().isEmpty) {
    cfg.ops!.appKey = cfg.appKey;
  }
  if (cfg.mpc != null && cfg.mpc!.appKey.trim().isEmpty) {
    cfg.mpc!.appKey = cfg.appKey;
  }
}

int wsTimeout(int? sec) => (sec != null && sec > 0) ? sec : 300;
