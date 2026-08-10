String _trim(String value) => value.trim();

(String, String)? _parseAddrAmountLine(String line) {
  final trimmed = _trim(line);
  final idx = trimmed.lastIndexOf(':');
  if (idx <= 0) return null;
  return (_trim(trimmed.substring(0, idx)), _trim(trimmed.substring(idx + 1)));
}

bool _amountStringsEqual(String a, String b) {
  final sa = _trim(a);
  final sb = _trim(b);
  final na = double.tryParse(sa);
  final nb = double.tryParse(sb);
  if (na != null && nb != null && na == nb) return true;
  return sa == sb;
}

bool _isZeroAmount(String value) {
  final n = double.tryParse(_trim(value));
  return n != null && n == 0;
}

Set<String> _txFromAddresses(List<dynamic>? txFrom) {
  final out = <String>{};
  for (final line in txFrom ?? const []) {
    final s = line.toString();
    final idx = s.indexOf(':');
    final addr = _trim(idx >= 0 ? s.substring(0, idx) : s);
    if (addr.isNotEmpty) out.add(addr);
  }
  return out;
}

int _maxAllowedExtraOutputs(String symbol) => symbol.toUpperCase() == 'BTC' ? 1 : 0;

void _validateExactPendingOutputs(
  Map<String, dynamic> tx,
  Map<String, String> to,
  int maxExtra,
) {
  final wantLines = to.entries.map((e) => '${_trim(e.key)}:${_trim(e.value)}').toSet();
  final found = <String>{};
  final txTo = (tx['txTo'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
  for (final line in txTo) {
    if (wantLines.contains(line)) found.add(line);
  }
  if (found.length != wantLines.length) {
    for (final line in wantLines) {
      if (!found.contains(line)) {
        throw StateError('missing tx.To entry "$line" in ${tx['txTo']}');
      }
    }
  }
  final extra = txTo.length - found.length;
  if (extra > maxExtra) {
    throw StateError(
      'unexpected extra outputs in tx.To: got ${txTo.length} entries, '
      'want ${wantLines.length} (+ at most $maxExtra change)',
    );
  }
}

void _validateBtcPendingOutputs(Map<String, dynamic> tx, Map<String, String> to) {
  final want = {for (final e in to.entries) _trim(e.key): _trim(e.value)};
  final found = <String>{};
  final extraLines = <String>[];
  final inputAddrs = _txFromAddresses(tx['txFrom'] as List?);
  final txTo = (tx['txTo'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];

  for (final line in txTo) {
    final parsed = _parseAddrAmountLine(line);
    if (parsed == null) throw StateError('invalid tx.To line "$line"');
    final (addr, amt) = parsed;
    final wantAmt = want[addr];
    if (wantAmt != null) {
      if (_isZeroAmount(wantAmt)) {
        if (!inputAddrs.contains(addr)) {
          throw StateError('cancel output not owned by input addresses: $addr');
        }
        found.add(addr);
        continue;
      }
      if (!_amountStringsEqual(wantAmt, amt)) {
        throw StateError('tx.To amount mismatch for $addr: got "$amt" want "$wantAmt"');
      }
      found.add(addr);
      continue;
    }
    extraLines.add(line);
  }

  for (final addr in want.keys) {
    if (!found.contains(addr)) {
      throw StateError('missing tx.To entry for "$addr" in ${tx['txTo']}');
    }
  }

  if (extraLines.length > 1) {
    throw StateError(
      'unexpected extra outputs in tx.To: got ${txTo.length} entries, '
      'want ${want.length} (+ at most 1 change)',
    );
  }
  if (extraLines.length == 1) {
    final parsed = _parseAddrAmountLine(extraLines[0]);
    if (parsed == null) throw StateError('invalid change output line "${extraLines[0]}"');
    if (!inputAddrs.contains(parsed.$1)) {
      throw StateError('change output not owned by input addresses: ${parsed.$1}');
    }
  }
}

void validateRawTradePending({
  required Map<String, dynamic> tx,
  required String sid,
  required String fromAccountId,
  required String symbol,
  required String contractAddress,
  required Map<String, String> to,
}) {
  if (tx['sid']?.toString() != sid) throw StateError('sid invalid');
  final coin = (tx['coin'] as Map?)?.cast<String, dynamic>() ?? const {};
  if (coin['symbol']?.toString() != symbol) throw StateError('symbol invalid');
  final contract = (coin['contract'] as Map?)?.cast<String, dynamic>() ?? const {};
  if ((contract['address']?.toString() ?? '') != contractAddress) {
    throw StateError('contractAddress invalid');
  }
  final account = (tx['account'] as Map?)?.cast<String, dynamic>() ?? const {};
  if (account['accountID']?.toString() != fromAccountId) {
    throw StateError(
      'accountID invalid, got=${account['accountID'] ?? ''} want=$fromAccountId',
    );
  }
  if (symbol.toUpperCase() == 'BTC') {
    _validateBtcPendingOutputs(tx, to);
    return;
  }
  _validateExactPendingOutputs(tx, to, _maxAllowedExtraOutputs(symbol));
}

void validateSummaryRawPending({
  required Map<String, dynamic> tx,
  required String sid,
  required String accountId,
  required String symbol,
  required String target,
}) {
  final txSid = tx['sid']?.toString() ?? '';
  if (!txSid.startsWith(sid)) {
    throw StateError('sid invalid, got=$txSid want prefix=$sid');
  }
  final coin = (tx['coin'] as Map?)?.cast<String, dynamic>() ?? const {};
  if (coin['symbol']?.toString() != symbol) throw StateError('symbol invalid');
  final account = (tx['account'] as Map?)?.cast<String, dynamic>() ?? const {};
  if (account['accountID']?.toString() != accountId) {
    throw StateError(
      'accountID invalid, got=${account['accountID'] ?? ''} want=$accountId',
    );
  }
  final toEntries = (tx['txTo'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
  if (toEntries.length != 1) {
    throw StateError('summary tx target count=${toEntries.length} want 1');
  }
  final parsed = _parseAddrAmountLine(toEntries[0]);
  if (parsed == null) throw StateError('invalid summary tx.To line "${toEntries[0]}"');
  if (parsed.$1.toLowerCase() != _trim(target).toLowerCase()) {
    throw StateError('summary target mismatch, got=${parsed.$1} want=$target');
  }
}
