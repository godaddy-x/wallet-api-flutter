# Wallet API SDK (Flutter / Dart)

Dart SDK for **OPS** and **MPC** WebSocket integration: signed transfers, wallet lifecycle, and MPC signing.

Architecture mirrors [wallet-api-go](https://github.com/godaddy-x/wallet-api-go) / [wallet-api-python](https://github.com/godaddy-x/wallet-api-python):

```
lib/src/crypto/      — AES-GCM, ML-DSA-87, ML-KEM-1024, canonical HMAC
lib/src/protocol/    — Plan2 envelopes and public-key payloads
lib/src/transport/   — SocketSDK (long-lived WebSocket)
lib/src/client/      — WalletClient, trade hooks, config
config/              — sample ops.json / cli.json
```

## Requirements

- Dart **3.12+** (Flutter apps use the same package)
- **VM / mobile / desktop** (`dart:io`) — custom `Authorization` headers are required; web is not supported
- Reachable **OPS** and/or **MPC broker** endpoints

## Install

### From path / GitHub

```yaml
dependencies:
  wallet_api:
    git:
      url: https://github.com/godaddy-x/wallet-api-flutter.git
      ref: v0.1.0
```

### Local development

```bash
git clone https://github.com/godaddy-x/wallet-api-flutter.git
cd wallet-api-flutter
dart pub get
dart test
```

## Quick start — connect and transfer

```dart
import 'dart:io';

import 'package:wallet_api/wallet_api.dart';

Future<void> main() async {
  final client = await WalletClient.fromFiles(
    'config/ops.json',
    'config/cli.json',
    appKey: Platform.environment['APP_KEY'] ?? '',
    wsTimeoutSec: 300,
  );

  try {
    final status = client.connected();
    if (!status.ops || !status.mpc) {
      throw StateError('OPS and MPC must both be connected');
    }

    final out = await client.transfer(
      fromAccountId: 'account-id',
      to: {'0xabc...': '0.01'},
      symbol: 'ETH',
    );
    print('txID=${out.result['txID']} createMs=${out.timings.createMs}');
  } finally {
    await client.close();
  }
}
```

`transfer()` runs **OPS CreateTrade → MPC SignTransaction → OPS SubmitTrade**.

Connect only one side with an empty path:

```dart
final opsOnly = await WalletClient.fromFiles('config/ops.json', '', appKey: appKey);
final mpcOnly = await WalletClient.fromFiles('', 'config/cli.json');
```

## Configuration

Sample shapes ship in `config/`. Replace values with credentials issued for your app.

**OPS — `config/ops.json`**

```json
{
  "domain": "ops.example.com",
  "keyPath": "/api/PublicKey",
  "loginPath": "/api/Login",
  "appID": "your-app-id",
  "appKey": "hex-encoded-app-key",
  "clientNo": "202606271558577948",
  "ssl": false,
  "clientPrk": "base64-mldsa-seed-32-bytes",
  "serverPub": "base64-mldsa-server-public-key"
}
```

**MPC — `config/cli.json`**

```json
{
  "domain": "mpc.example.com",
  "keyPath": "/api/PublicKey",
  "loginPath": "/api/Login",
  "clientNo": 3,
  "source": "your-app-id",
  "clientPrk": "base64-mldsa-seed-32-bytes",
  "serverPub": "base64-mldsa-server-public-key",
  "ssl": false
}
```

Notes:

- OPS login uses `appID` + `appKey` (HMAC: **data** = app key bytes, **key** = `nonce + time + source`).
- MPC Plan2 login uses `source` when no app key is configured on the MPC side.
- `clientPrk` is a **32-byte ML-DSA seed** (base64), not an expanded secret key.
- Prefer string `clientNo` in JSON for large values; Dart parses both safely.

### Programmatic configuration

```dart
final client = await WalletClient.create(Config(
  appKey: appKey,
  wsTimeoutSec: 300,
  ops: SdkConfig(
    domain: 'ops.example.com',
    appID: appId,
    appKey: appKey,
    clientNo: clientNo,
    clientPrk: clientPrk,
    serverPub: serverPub,
  ),
  mpc: SdkConfig(
    domain: 'mpc.example.com',
    clientNo: 3,
    source: appId,
    clientPrk: mpcClientPrk,
    serverPub: mpcServerPub,
  ),
));
```

## Protocol

| Phase | Plan | Transport |
|-------|------|-----------|
| Plan2 bootstrap + login | `p=2` | WebSocket `/ws` + ML-KEM + ML-DSA + AES-GCM |
| Post-login business | `p=1` | JWT `Authorization` + AES-GCM body |
| Heartbeat | `p=0` | `/ws/ping` |

- `SHARED_INFO = "freego-ecdh-aes-gcm"` for HKDF key derivation
- Empty-key HMAC uses zero-length key (matches Java BouncyCastle behavior)

## Trade hooks

When `appKey` is set, default hooks validate OPS `pendingSignTx` before MPC signing:

- `validatePendingDataSignHook`
- `validateCreateTradeRequestHook`
- `validateCreateSummaryTxRequestHook`
- `validateRbfSidRequestHook`

Disable with `Config(disableDefaultTradeHooks: true)`.

## Security

- Do not log or persist `appKey`, `clientPrk`, or JWT secrets.
- OPS enforces client IP whitelist for non-loopback callers.
- Call `close()` on shutdown.

## License

MIT
