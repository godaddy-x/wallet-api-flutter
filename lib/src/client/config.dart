import 'dart:async';

import '../protocol/envelope.dart';
import 'trade_hook.dart';

typedef ConfigHook = FutureOr<void> Function(Config cfg);
typedef OpsAuthTokenRefresh = Future<AuthToken> Function();

class SdkConfig {
  SdkConfig({
    this.domain = '',
    this.keyPath = '/api/PublicKey',
    this.loginPath = '/api/Login',
    this.source = '',
    this.appID = '',
    this.appKey = '',
    this.clientPrk = '',
    this.serverPub = '',
    this.clientNo = 0,
    this.ssl = false,
  });

  String domain;
  String keyPath;
  String loginPath;
  String source;
  String appID;
  String appKey;
  String clientPrk;
  String serverPub;
  int clientNo;
  bool ssl;
}

class Config {
  Config({
    this.ops,
    this.mpc,
    this.appKey = '',
    this.wsTimeoutSec = 300,
    List<TradeCreatedHook>? tradeCreatedHooks,
    this.disableDefaultTradeHooks = false,
    this.opsAuthToken,
    this.opsTokenRefresh,
  }) : tradeCreatedHooks = tradeCreatedHooks ?? [];

  SdkConfig? ops;
  SdkConfig? mpc;
  String appKey;
  int wsTimeoutSec;
  List<TradeCreatedHook> tradeCreatedHooks;
  bool disableDefaultTradeHooks;
  /// C 端 App：AppUserLogin 已签发的 JWT，直连 OPS 时跳过 /api/Login。
  AuthToken? opsAuthToken;
  OpsAuthTokenRefresh? opsTokenRefresh;
}

class TransferTimings {
  TransferTimings({required this.createMs, required this.signMs});

  final int createMs;
  final int signMs;

  @override
  String toString() => 'TransferTimings(createMs: $createMs, signMs: $signMs)';
}

List<ConfigHook> normalizeConfigHooks(Object? hooks) {
  if (hooks == null) return [];
  if (hooks is List<ConfigHook>) return hooks.whereType<ConfigHook>().toList();
  if (hooks is ConfigHook) return [hooks];
  return [];
}
