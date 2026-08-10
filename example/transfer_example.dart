import 'dart:io';

import 'package:wallet_api/wallet_api.dart';

/// Quick start: connect OPS + MPC and run a signed single transfer.
///
/// ```bash
/// dart run example/transfer_example.dart
/// ```
Future<void> main() async {
  final appKey = Platform.environment['APP_KEY'] ?? '';
  final fromAccountId = Platform.environment['FROM_ACCOUNT_ID'] ?? '';
  final toAddress = Platform.environment['TO_ADDRESS'] ?? '';
  final amount = Platform.environment['AMOUNT'] ?? '0.01';
  final symbol = Platform.environment['SYMBOL'] ?? 'ETH';

  if (fromAccountId.isEmpty || toAddress.isEmpty) {
    stderr.writeln(
      'Set FROM_ACCOUNT_ID, TO_ADDRESS (and optionally APP_KEY, AMOUNT, SYMBOL).',
    );
    exit(2);
  }

  final client = await WalletClient.fromFiles(
    'config/ops.json',
    'config/cli.json',
    appKey: appKey,
    wsTimeoutSec: 300,
  );

  try {
    final status = client.connected();
    if (!status.ops || !status.mpc) {
      throw StateError('OPS and MPC must both be connected');
    }

    final out = await client.transfer(
      fromAccountId: fromAccountId,
      to: {toAddress: amount},
      symbol: symbol,
    );
    stdout.writeln('txID=${out.result['txID']} timings=${out.timings}');
  } finally {
    await client.close();
  }
}
