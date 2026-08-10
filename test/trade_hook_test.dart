import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:test/test.dart';
import 'package:wallet_api/wallet_api.dart';

void main() {
  group('trade hooks', () {
    test('validateCreateTradeRequestHook matches transfer', () async {
      final raw = {
        'sid': 'sid-1',
        'coin': {'symbol': 'ETH'},
        'account': {'accountID': 'acc-1'},
        'txTo': ['0xabc:0.01'],
      };
      final pending = [
        {'data': jsonEncode(raw)},
      ];
      final req = {
        'sid': 'sid-1',
        'accountID': 'acc-1',
        'coin': {'symbol': 'ETH'},
        'to': {'0xabc': '0.01'},
      };
      await Future.sync(
        () => validateCreateTradeRequestHook()(
          TradeCreatedContext(
            kind: tradeKindCreate,
            request: req,
            pending: pending.map((e) => Map<String, dynamic>.from(e)).toList(),
            client: null,
          ),
        ),
      );

      (req['to'] as Map)['0xabc'] = '0.02';
      expect(
        () => validateCreateTradeRequestHook()(
          TradeCreatedContext(
            kind: tradeKindCreate,
            request: req,
            pending: pending.map((e) => Map<String, dynamic>.from(e)).toList(),
            client: null,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('validateCreateTradeRequestHook allows BTC change', () async {
      final raw = {
        'sid': 'sid-btc',
        'coin': {'symbol': 'BTC'},
        'account': {'accountID': 'acc-1'},
        'txFrom': ['bcrt1qay6v8dmyqu6lu6z448fx9re0c5nzy2ye22shua:50'],
        'txTo': [
          'bcrt1qzqwuj487l2weae4vqpdqfku5gk7ssj8h5ry6ec:0.0001',
          'bcrt1qay6v8dmyqu6lu6z448fx9re0c5nzy2ye22shua:41.79989000',
        ],
      };
      final pending = [
        {'data': jsonEncode(raw)},
      ];
      final req = {
        'sid': 'sid-btc',
        'accountID': 'acc-1',
        'coin': {'symbol': 'BTC'},
        'to': {'bcrt1qzqwuj487l2weae4vqpdqfku5gk7ssj8h5ry6ec': '0.0001'},
      };
      await Future.sync(
        () => validateCreateTradeRequestHook()(
          TradeCreatedContext(
            kind: tradeKindCreate,
            request: req,
            pending: pending.map((e) => Map<String, dynamic>.from(e)).toList(),
            client: null,
          ),
        ),
      );
    });

    test('validatePendingDataSignHook verifies HMAC', () async {
      const appKeyHex = '30313233343536373839616263646566'; // "0123456789abcdef"
      final key = utf8.encode('0123456789abcdef');
      const data = '{"sid":"s1"}';
      final dataSign = base64Encode(
        crypto_pkg.Hmac(crypto_pkg.sha256, key).convert(utf8.encode(data)).bytes,
      );
      final pending = [
        {'data': data, 'dataSign': dataSign},
      ];
      await Future.sync(
        () => validatePendingDataSignHook(appKeyHex)(
          TradeCreatedContext(
            kind: tradeKindCreate,
            request: null,
            pending: pending.map((e) => Map<String, dynamic>.from(e)).toList(),
            client: null,
          ),
        ),
      );

      pending[0]['dataSign'] = 'bad';
      expect(
        () => validatePendingDataSignHook(appKeyHex)(
          TradeCreatedContext(
            kind: tradeKindCreate,
            request: null,
            pending: pending.map((e) => Map<String, dynamic>.from(e)).toList(),
            client: null,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
