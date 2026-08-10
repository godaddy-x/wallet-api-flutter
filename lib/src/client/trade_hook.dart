import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/canonical.dart';
import 'trade_validate.dart';

typedef TradeCreatedHook = FutureOr<void> Function(TradeCreatedContext ctx);

const tradeKindCreate = 'create_trade';
const tradeKindSpeedUp = 'speed_up';
const tradeKindCancel = 'cancel';
const tradeKindSummary = 'summary';
const tradeKindBatchTransfer = 'batch_transfer';
const tradeKindBatchApprove = 'batch_approve';
const tradeKindBatchSpeedUp = 'batch_speed_up';
const tradeKindBatchCancel = 'batch_cancel';
const tradeKindDeploy = 'deploy';

class TradeCreatedContext {
  TradeCreatedContext({
    required this.kind,
    required this.request,
    required this.pending,
    required this.client,
  });

  final String kind;
  final Object? request;
  final List<Map<String, dynamic>> pending;
  final Object? client;
}

Map<String, dynamic> firstPending(TradeCreatedContext ctx) {
  if (ctx.pending.isEmpty) throw StateError('empty pendingSignTx');
  return ctx.pending.first;
}

Map<String, dynamic> decodeRaw(TradeCreatedContext ctx) {
  final pending = firstPending(ctx);
  final data = pending['data']?.toString() ?? '';
  if (data.isEmpty) throw StateError('pendingSignTx.data is empty');
  try {
    return Map<String, dynamic>.from(jsonDecode(data) as Map);
  } catch (e) {
    throw StateError('unmarshal raw tx: $e');
  }
}

Map<String, dynamic> _decodePendingRaw(Map<String, dynamic> pending) {
  final data = pending['data']?.toString() ?? '';
  if (data.isEmpty) throw StateError('pendingSignTx.data is empty');
  try {
    return Map<String, dynamic>.from(jsonDecode(data) as Map);
  } catch (e) {
    throw StateError('unmarshal raw tx: $e');
  }
}

void _validatePendingDataSign(Uint8List appKey, Map<String, dynamic> tx) {
  final data = tx['data']?.toString() ?? '';
  if (data.isEmpty) throw StateError('pendingSignTx.data is empty');
  final expected = hmacSha256(utf8.encode(data), appKey);
  if (!compareBase64Sign(expected, tx['dataSign']?.toString() ?? '')) {
    throw StateError('tx data check sign invalid');
  }
}

TradeCreatedHook validatePendingDataSignHook(String appKeyHex) {
  late final Uint8List key;
  try {
    key = Uint8List.fromList(_hexDecode(appKeyHex));
  } catch (e) {
    return (_) => throw StateError('invalid appKey: $e');
  }
  if (key.isEmpty) {
    return (_) => throw StateError('invalid appKey: empty hex');
  }
  return (ctx) {
    for (var i = 0; i < ctx.pending.length; i++) {
      try {
        _validatePendingDataSign(key, ctx.pending[i]);
      } catch (e) {
        throw StateError('pending[$i]: $e');
      }
    }
  };
}

TradeCreatedHook validateCreateTradeRequestHook() {
  return (ctx) {
    if (ctx.kind != tradeKindCreate) return;
    final req = (ctx.request as Map?)?.cast<String, dynamic>() ?? const {};
    final coin = (req['coin'] as Map?)?.cast<String, dynamic>() ?? const {};
    if ((req['sid']?.toString() ?? '').isEmpty ||
        (req['accountID']?.toString() ?? '').isEmpty ||
        (coin['symbol']?.toString() ?? '').isEmpty) {
      return;
    }
    final toRaw = req['to'];
    if (toRaw is! Map || toRaw.isEmpty) return;
    final to = <String, String>{
      for (final e in toRaw.entries) e.key.toString(): e.value.toString(),
    };
    final tx = decodeRaw(ctx);
    validateRawTradePending(
      tx: tx,
      sid: req['sid'].toString(),
      fromAccountId: req['accountID'].toString(),
      symbol: coin['symbol'].toString(),
      contractAddress: coin['contractAddress']?.toString() ?? '',
      to: to,
    );
  };
}

TradeCreatedHook validateCreateSummaryTxRequestHook() {
  return (ctx) {
    if (ctx.kind != tradeKindSummary) return;
    final req = (ctx.request as Map?)?.cast<String, dynamic>() ?? const {};
    final target = (req['address']?.toString() ?? '').trim();
    if (target.isEmpty) throw StateError('summary target address is empty');
    final coin = (req['coin'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (var i = 0; i < ctx.pending.length; i++) {
      try {
        final tx = _decodePendingRaw(ctx.pending[i]);
        validateSummaryRawPending(
          tx: tx,
          sid: req['sid']?.toString() ?? '',
          accountId: req['accountID']?.toString() ?? '',
          symbol: coin['symbol']?.toString() ?? '',
          target: target,
        );
      } catch (e) {
        throw StateError('pending[$i]: $e');
      }
    }
  };
}

TradeCreatedHook validateRbfSidRequestHook() {
  return (ctx) {
    if (ctx.kind != tradeKindSpeedUp && ctx.kind != tradeKindCancel) return;
    final req = (ctx.request as Map?)?.cast<String, dynamic>() ?? const {};
    final sid = req['sid']?.toString() ?? '';
    final accountId = req['accountID']?.toString() ?? '';
    for (var i = 0; i < ctx.pending.length; i++) {
      try {
        final tx = _decodePendingRaw(ctx.pending[i]);
        if (tx['sid']?.toString() != sid) {
          throw StateError('sid invalid, got=${tx['sid'] ?? ''} want=$sid');
        }
        final account = (tx['account'] as Map?)?.cast<String, dynamic>() ?? const {};
        if (account['accountID']?.toString() != accountId) {
          throw StateError(
            'accountID invalid, got=${account['accountID'] ?? ''} want=$accountId',
          );
        }
      } catch (e) {
        throw StateError('pending[$i]: $e');
      }
    }
  };
}

List<TradeCreatedHook> defaultTradeCreatedHooks(String appKey) {
  if (appKey.trim().isEmpty) return [];
  return [
    validatePendingDataSignHook(appKey),
    validateCreateTradeRequestHook(),
    validateCreateSummaryTxRequestHook(),
    validateRbfSidRequestHook(),
  ];
}

Future<void> runTradeCreatedHooks({
  required Object? client,
  required List<TradeCreatedHook> hooks,
  required String kind,
  required Object? request,
  required List<Map<String, dynamic>>? pending,
}) async {
  if (pending == null || pending.isEmpty) {
    throw StateError('empty pendingSignTx');
  }
  if (hooks.isEmpty) return;
  final ctx = TradeCreatedContext(
    kind: kind,
    request: request,
    pending: pending,
    client: client,
  );
  for (final hook in hooks) {
    await Future.sync(() => hook(ctx));
  }
}

List<int> _hexDecode(String hex) {
  final cleaned = hex.trim();
  if (cleaned.length.isOdd) throw FormatException('odd hex length');
  final out = <int>[];
  for (var i = 0; i < cleaned.length; i += 2) {
    out.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
  }
  return out;
}
