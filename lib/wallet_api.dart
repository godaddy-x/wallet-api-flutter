/// Wallet API SDK for Dart/Flutter: OPS and MPC WebSocket integration.
library;

export 'src/client/config.dart';
export 'src/client/trade_hook.dart'
    show
        TradeCreatedContext,
        TradeCreatedHook,
        tradeKindBatchApprove,
        tradeKindBatchCancel,
        tradeKindBatchSpeedUp,
        tradeKindBatchTransfer,
        tradeKindCancel,
        tradeKindCreate,
        tradeKindDeploy,
        tradeKindSpeedUp,
        tradeKindSummary,
        validateCreateSummaryTxRequestHook,
        validateCreateTradeRequestHook,
        validatePendingDataSignHook,
        validateRbfSidRequestHook;
export 'src/client/util.dart' show WalletApiException, errNilRequest;
export 'src/client/wallet_client.dart';
export 'src/protocol/envelope.dart' show AuthToken;
export 'src/transport/socket_sdk.dart' show PushMessageHandler, SocketSDK, SocketSdkOptions;
