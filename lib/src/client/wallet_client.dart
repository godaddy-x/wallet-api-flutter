import 'package:uuid/uuid.dart';

import '../transport/socket_sdk.dart';
import 'config.dart';
import 'socket.dart';
import 'trade_hook.dart';
import 'util.dart';

class TransferResult {
  TransferResult({required this.result, required this.timings});

  final Map<String, dynamic> result;
  final TransferTimings timings;
}

/// Minimal wallet SDK: connect OPS/MPC and run signed transfers.
class WalletClient {
  WalletClient._(this._appKey, this._wsTimeoutSec, this._tradeHooks);

  final String _appKey;
  final int _wsTimeoutSec;
  final List<TradeCreatedHook> _tradeHooks;
  SocketSDK? _opsSdk;
  SocketSDK? _mpcSdk;

  String get appKey => _appKey;

  static Future<WalletClient> create(
    Config cfg, [
    Object? hooks,
  ]) async {
    for (final hook in normalizeConfigHooks(hooks)) {
      await Future.sync(() => hook(cfg));
    }
    normalizeConfig(cfg);
    final tradeHooks = <TradeCreatedHook>[];
    if (!cfg.disableDefaultTradeHooks) {
      tradeHooks.addAll(defaultTradeCreatedHooks(cfg.appKey));
    }
    tradeHooks.addAll(cfg.tradeCreatedHooks);

    final client = WalletClient._(cfg.appKey, wsTimeout(cfg.wsTimeoutSec), tradeHooks);
    if (cfg.ops != null && sdkConfigEnabled(cfg.ops)) {
      if (cfg.opsAuthToken != null) {
        client._opsSdk = await newLongLivedSocketWithAuth(
          cfg.ops!,
          cfg.opsAuthToken!,
          onSessionExpired: cfg.opsOnSessionExpired,
        );
      } else {
        client._opsSdk = await newLongLivedSocket(cfg.ops!);
      }
    }
    try {
      if (cfg.mpc != null && sdkConfigEnabled(cfg.mpc)) {
        client._mpcSdk = await newLongLivedSocket(cfg.mpc!);
      }
    } catch (_) {
      await client.close();
      rethrow;
    }
    return client;
  }

  static Future<WalletClient> fromFiles(
    String opsPath,
    String mpcPath, {
    String appKey = '',
    int wsTimeoutSec = 300,
    Object? hooks,
  }) async {
    final cfg = Config(appKey: appKey, wsTimeoutSec: wsTimeoutSec);
    if (opsPath.trim().isNotEmpty) {
      cfg.ops = readSdkConfigFile(opsPath);
    }
    if (mpcPath.trim().isNotEmpty) {
      cfg.mpc = readSdkConfigFile(mpcPath);
    }
    return create(cfg, hooks);
  }

  ({bool ops, bool mpc}) connected() => (
        ops: _opsSdk?.isWebSocketConnected() ?? false,
        mpc: _mpcSdk?.isWebSocketConnected() ?? false,
      );

  Future<void> close() async {
    await _opsSdk?.disconnectWebSocket();
    await _mpcSdk?.disconnectWebSocket();
    _opsSdk = null;
    _mpcSdk = null;
  }

  SocketSDK _requireOps() {
    final sdk = _opsSdk;
    if (sdk == null) throw StateError('ops not connected');
    return sdk;
  }

  SocketSDK _requireMpc() {
    final sdk = _mpcSdk;
    if (sdk == null) throw StateError('mpc not connected');
    return sdk;
  }

  Future<Map<String, dynamic>> _sendOps(String path, Map<String, dynamic> req) async {
    if (isNilRequest(req)) throw errNilRequest;
    final res = await _requireOps().sendWebSocketMessage(
      path,
      req,
      waitResponse: true,
      encryptRequest: true,
      timeoutSec: _wsTimeoutSec,
    );
    if (res == null) throw StateError('$path: empty response');
    return Map<String, dynamic>.from(res as Map);
  }

  Future<Map<String, dynamic>> _sendCli(String path, Map<String, dynamic> req) async {
    if (isNilRequest(req)) throw errNilRequest;
    final res = await _requireMpc().sendWebSocketMessage(
      path,
      req,
      waitResponse: true,
      encryptRequest: true,
      timeoutSec: _wsTimeoutSec,
    );
    if (res == null) throw StateError('$path: empty response');
    return Map<String, dynamic>.from(res as Map);
  }

  Future<Map<String, dynamic>> _sendOpsTrade(
    String path,
    Map<String, dynamic> req,
    String kind,
    String pendingKey,
  ) async {
    final res = await _sendOps(path, req);
    final pendingRaw = res[pendingKey];
    final pending = <Map<String, dynamic>>[];
    if (pendingRaw is List) {
      for (final item in pendingRaw) {
        if (item is Map) {
          pending.add(Map<String, dynamic>.from(item));
        }
      }
    }
    await runTradeCreatedHooks(
      client: this,
      hooks: _tradeHooks,
      kind: kind,
      request: req,
      pending: pending,
    );
    return res;
  }

  void addTradeCreatedHook(TradeCreatedHook hook) => _tradeHooks.add(hook);

  /// CreateTrade → SignTransaction → SubmitTrade.
  Future<TransferResult> transfer({
    required String fromAccountId,
    required Map<String, String> to,
    required String symbol,
    String contractAddress = '',
  }) async {
    if (_opsSdk == null || _mpcSdk == null) {
      throw StateError('ops and mpc must both be connected for Transfer');
    }
    final sid = const Uuid().v4().replaceAll('-', '');
    final createSw = Stopwatch()..start();
    final createRes = await createTrade({
      'sid': sid,
      'accountID': fromAccountId,
      'coin': {
        'symbol': symbol,
        'contractAddress': contractAddress,
      },
      'to': to,
    });
    createSw.stop();

    final pendingList = createRes['pendingSignTx'];
    if (pendingList is! List || pendingList.isEmpty) {
      throw StateError('CreateTrade sid=$sid: missing pendingSignTx');
    }
    final pending = Map<String, dynamic>.from(pendingList.first as Map);
    if ((pending['data']?.toString() ?? '').isEmpty) {
      throw StateError('CreateTrade sid=$sid: missing pendingSignTx data');
    }

    final signSw = Stopwatch()..start();
    final signRes = await signTransaction(
      _mpcSdk!,
      {
        'type': 0,
        'data': pending['data'],
        'tradeSign': pending['tradeSign'],
      },
      _wsTimeoutSec,
    );
    signSw.stop();
    final signerList = signRes['signerList'];
    if (signerList is! List || signerList.isEmpty) {
      throw StateError('SignTransaction sid=$sid: signerList missing');
    }
    pending['signerList'] = signerList;
    final result = await submitTrade({'pendingSignTx': pending});
    return TransferResult(
      result: result,
      timings: TransferTimings(
        createMs: createSw.elapsedMilliseconds,
        signMs: signSw.elapsedMilliseconds,
      ),
    );
  }

  // --- OPS ---

  Future<Map<String, dynamic>> createAccount(Map<String, dynamic> req) =>
      _sendOps('/api/CreateAccount', req);

  Future<Map<String, dynamic>> findAccountByAccountId(Map<String, dynamic> req) =>
      _sendOps('/api/FindAccountByAccountID', req);

  Future<Map<String, dynamic>> findAccountByWalletId(Map<String, dynamic> req) =>
      _sendOps('/api/FindAccountByWalletID', req);

  Future<Map<String, dynamic>> getBalanceByAccount(Map<String, dynamic> req) =>
      _sendOps('/api/GetBalanceByAccount', req);

  Future<Map<String, dynamic>> findSymbolPriceList(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/FindSymbolPriceList', req);

  Future<Map<String, dynamic>> getAccountBalanceList(Map<String, dynamic> req) =>
      _sendOps('/api/GetAccountBalanceList', req);

  Future<Map<String, dynamic>> getBalancesByAccount(Map<String, dynamic> req) =>
      _sendOps('/api/GetBalancesByAccount', req);

  Future<Map<String, dynamic>> importAddress(Map<String, dynamic> req) =>
      _sendOps('/api/ImportAddress', req);

  /// 为钱包新增币种地址：HD 派生账户+地址并同事务入库。
  Future<Map<String, dynamic>> createCoinAddressOps(Map<String, dynamic> req) =>
      _sendOps('/api/CreateCoinAddress', req);

  Future<Map<String, dynamic>> findAddressByAddress(Map<String, dynamic> req) =>
      _sendOps('/api/FindAddressByAddress', req);

  Future<Map<String, dynamic>> findAddressByAccountId(Map<String, dynamic> req) =>
      _sendOps('/api/FindAddressByAccountID', req);

  Future<Map<String, dynamic>> verifyAddress(Map<String, dynamic> req) =>
      _sendOps('/api/VerifyAddress', req);

  Future<Map<String, dynamic>> getBalanceByAddress(Map<String, dynamic> req) =>
      _sendOps('/api/GetBalanceByAddress', req);

  Future<Map<String, dynamic>> getAddressBalanceList(Map<String, dynamic> req) =>
      _sendOps('/api/GetAddressBalanceList', req);

  Future<Map<String, dynamic>> getContracts(Map<String, dynamic> req) =>
      _sendOps('/api/GetContracts', req);

  Future<Map<String, dynamic>> getContractTemplates(Map<String, dynamic> req) =>
      _sendOps('/api/GetContractTemplates', req);

  Future<Map<String, dynamic>> deployContract(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/DeployContract', req, tradeKindDeploy, 'pendingSignTx');

  Future<Map<String, dynamic>> submitDeployContract(Map<String, dynamic> req) =>
      _sendOps('/api/SubmitDeployContract', req);

  Future<Map<String, dynamic>> submitSmartContractTrade(Map<String, dynamic> req) =>
      _sendOps('/api/SubmitSmartContractTrade', req);

  Future<Map<String, dynamic>> symbolBlockList(Map<String, dynamic> req) =>
      _sendOps('/api/SymbolBlockList', req);

  Future<Map<String, dynamic>> createWallet(Map<String, dynamic> req) =>
      _sendOps('/api/CreateWallet', req);

  Future<Map<String, dynamic>> findWalletByWalletId(Map<String, dynamic> req) =>
      _sendOps('/api/FindWalletByWalletID', req);

  /// OPS wallet list for the authenticated app (paginated via `limit` / `lastID`).
  Future<Map<String, dynamic>> opsFindWalletList([Map<String, dynamic>? req]) =>
      _sendOps('/api/FindWalletList', req ?? {});

  /// OPS home assets: wallets + grouped balances + USD totals in one call.
  Future<Map<String, dynamic>> opsFindWalletHomeList([
    Map<String, dynamic>? req,
  ]) =>
      _sendOps('/api/FindWalletHomeList', req ?? {});

  Future<Map<String, dynamic>> getTransactionFeeEstimated(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/GetTransactionFeeEstimated', req);

  Future<Map<String, dynamic>> createTrade(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/CreateTrade', req, tradeKindCreate, 'pendingSignTx');

  Future<Map<String, dynamic>> submitTrade(Map<String, dynamic> req) =>
      _sendOps('/api/SubmitTrade', req);

  Future<Map<String, dynamic>> speedUpTransferTrade(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/SpeedUpTransferTrade', req, tradeKindSpeedUp, 'pendingSignTx');

  Future<Map<String, dynamic>> cancelTransferTrade(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/CancelTransferTrade', req, tradeKindCancel, 'pendingSignTx');

  Future<Map<String, dynamic>> createSummaryTx(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/CreateSummaryTx', req, tradeKindSummary, 'summaryPendingSignTx');

  Future<Map<String, dynamic>> evaluateSummaryFeeDeficit(Map<String, dynamic> req) =>
      _sendOps('/api/EvaluateSummaryFeeDeficit', req);

  Future<Map<String, dynamic>> createBatchTransferTrade(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/CreateBatchTransferTrade', req, tradeKindBatchTransfer, 'pendingSignTx');

  Future<Map<String, dynamic>> createBatchTransferApproveTrade(Map<String, dynamic> req) =>
      _sendOpsTrade(
        '/api/CreateBatchTransferApproveTrade',
        req,
        tradeKindBatchApprove,
        'pendingSignTx',
      );

  Future<Map<String, dynamic>> getBatchTransferAllowance(Map<String, dynamic> req) =>
      _sendOps('/api/GetBatchTransferAllowance', req);

  Future<Map<String, dynamic>> createStakeTrade(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/CreateStakeTrade', req, tradeKindCreate, 'pendingSignTx');

  Future<Map<String, dynamic>> createUnstakeTrade(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/CreateUnstakeTrade', req, tradeKindCreate, 'pendingSignTx');

  Future<Map<String, dynamic>> createWithdrawUnfreezeTrade(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/CreateWithdrawUnfreezeTrade', req, tradeKindCreate, 'pendingSignTx');

  Future<Map<String, dynamic>> getAccountResourceDetail(Map<String, dynamic> req) =>
      _sendOps('/api/GetAccountResourceDetail', req);

  Future<Map<String, dynamic>> speedUpBatchTransferTrade(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/SpeedUpBatchTransferTrade', req, tradeKindBatchSpeedUp, 'pendingSignTx');

  Future<Map<String, dynamic>> cancelBatchTransferTrade(Map<String, dynamic> req) =>
      _sendOpsTrade('/api/CancelBatchTransferTrade', req, tradeKindBatchCancel, 'pendingSignTx');

  Future<Map<String, dynamic>> createSubscribe(Map<String, dynamic> req) =>
      _sendOps('/api/CreateSubscribe', req);

  Future<Map<String, dynamic>> findTradeLog(Map<String, dynamic> req) =>
      _sendOps('/api/FindTradeLog', req);

  Future<Map<String, dynamic>> findTradeNewly(Map<String, dynamic> req) =>
      _sendOps('/api/FindTradeNewly', req);

  Future<Map<String, dynamic>> findBalanceLog(Map<String, dynamic> req) =>
      _sendOps('/api/FindBalanceLog', req);

  Future<Map<String, dynamic>> findMonitorAlert(Map<String, dynamic> req) =>
      _sendOps('/api/FindMonitorAlert', req);

  Future<Map<String, dynamic>> getBlockStatus(Map<String, dynamic> req) =>
      _sendOps('/api/GetBlockStatus', req);

  // --- MPC ---

  Future<Map<String, dynamic>> findWalletList([Map<String, dynamic>? req]) =>
      _sendCli('/api/FindWalletList', req ?? {});

  Future<Map<String, dynamic>> createMpcWallet(Map<String, dynamic> req) =>
      _sendCli('/api/CreateMPCWallet', req);

  /// OPS 代理 broker keygen（api_main mpccli → broker CreateMPCWallet）。
  Future<Map<String, dynamic>> createMpcWalletOps(Map<String, dynamic> req) =>
      _sendOps('/api/CreateMPCWallet', req);

  /// 查询 Keygen 参与方 MPC node 是否在线（broker 在线集）。
  Future<Map<String, dynamic>> checkMpcParticipantsOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/CheckMPCParticipants', req);

  Future<Map<String, dynamic>> createWalletKeygenInviteOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/CreateWalletKeygenInvite', req);

  Future<Map<String, dynamic>> getWalletKeygenInviteOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/GetWalletKeygenInvite', req);

  Future<Map<String, dynamic>> approveWalletKeygenInviteOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/ApproveWalletKeygenInvite', req);

  Future<Map<String, dynamic>> rejectWalletKeygenInviteOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/RejectWalletKeygenInvite', req);

  Future<Map<String, dynamic>> cancelWalletKeygenInviteOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/CancelWalletKeygenInvite', req);

  Future<Map<String, dynamic>> cliCreateAccount(Map<String, dynamic> req) =>
      _sendCli('/api/CreateAccount', req);

  Future<Map<String, dynamic>> cliCreateAddress(Map<String, dynamic> req) =>
      _sendCli('/api/CreateAddress', req);

  Future<Map<String, dynamic>> signTransactionApi(Map<String, dynamic> req) async {
    if (isNilRequest(req)) throw errNilRequest;
    return signTransaction(_requireMpc(), req, _wsTimeoutSec);
  }

  // --- Transfer proposals (api_main) ---

  Future<Map<String, dynamic>> createTransferProposal(Map<String, dynamic> req) =>
      _sendOps('/api/CreateTransferProposal', req);

  Future<Map<String, dynamic>> listTransferProposals(Map<String, dynamic> req) =>
      _sendOps('/api/ListTransferProposals', req);

  Future<Map<String, dynamic>> getTransferProposal(Map<String, dynamic> req) =>
      _sendOps('/api/GetTransferProposal', req);

  Future<Map<String, dynamic>> approveTransferProposal(Map<String, dynamic> req) =>
      _sendOps('/api/ApproveTransferProposal', req);

  Future<Map<String, dynamic>> rejectTransferProposal(Map<String, dynamic> req) =>
      _sendOps('/api/RejectTransferProposal', req);

  Future<Map<String, dynamic>> cancelTransferProposal(Map<String, dynamic> req) =>
      _sendOps('/api/CancelTransferProposal', req);

  Future<Map<String, dynamic>> executeTransferProposal(Map<String, dynamic> req) =>
      _sendOps('/api/ExecuteTransferProposal', req);

  Future<Map<String, dynamic>> reportTransferProposalFailure(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/ReportTransferProposalFailure', req);

  // --- Friends & inbox (api_main) ---

  Future<Map<String, dynamic>> friendSendRequest(Map<String, dynamic> req) =>
      _sendOps('/api/FriendSendRequest', req);

  Future<Map<String, dynamic>> friendSearchUser(Map<String, dynamic> req) =>
      _sendOps('/api/FriendSearchUser', req);

  Future<Map<String, dynamic>> friendList(Map<String, dynamic> req) =>
      _sendOps('/api/FriendList', req);

  Future<Map<String, dynamic>> friendListRequests(Map<String, dynamic> req) =>
      _sendOps('/api/FriendListRequests', req);

  Future<Map<String, dynamic>> friendAcceptRequest(Map<String, dynamic> req) =>
      _sendOps('/api/FriendAcceptRequest', req);

  Future<Map<String, dynamic>> friendRejectRequest(Map<String, dynamic> req) =>
      _sendOps('/api/FriendRejectRequest', req);

  Future<Map<String, dynamic>> friendCancelRequest(Map<String, dynamic> req) =>
      _sendOps('/api/FriendCancelRequest', req);

  Future<Map<String, dynamic>> inboxList(Map<String, dynamic> req) =>
      _sendOps('/api/InboxList', req);

  Future<Map<String, dynamic>> inboxUnreadCount(Map<String, dynamic> req) =>
      _sendOps('/api/InboxUnreadCount', req);

  Future<Map<String, dynamic>> inboxMarkRead(Map<String, dynamic> req) =>
      _sendOps('/api/InboxMarkRead', req);

  Future<Map<String, dynamic>> friendChatSend(Map<String, dynamic> req) =>
      _sendOps('/api/FriendChatSend', req);

  Future<Map<String, dynamic>> friendChatThreadList(Map<String, dynamic> req) =>
      _sendOps('/api/FriendChatThreadList', req);

  Future<Map<String, dynamic>> friendChatMessageList(Map<String, dynamic> req) =>
      _sendOps('/api/FriendChatMessageList', req);

  Future<Map<String, dynamic>> friendChatMarkRead(Map<String, dynamic> req) =>
      _sendOps('/api/FriendChatMarkRead', req);

  Future<Map<String, dynamic>> friendChatRecall(Map<String, dynamic> req) =>
      _sendOps('/api/FriendChatRecall', req);

  Future<Map<String, dynamic>> friendChatImagePresignPut(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/FriendChatImagePresignPut', req);

  Future<Map<String, dynamic>> friendChatImageConfirm(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/FriendChatImageConfirm', req);

  Future<Map<String, dynamic>> friendChatImagePresignGet(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/FriendChatImagePresignGet', req);

  Future<Map<String, dynamic>> friendChatVoicePresignPut(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/FriendChatVoicePresignPut', req);

  Future<Map<String, dynamic>> friendChatVoiceConfirm(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/FriendChatVoiceConfirm', req);

  Future<Map<String, dynamic>> friendChatVoicePresignGet(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/FriendChatVoicePresignGet', req);

  Future<Map<String, dynamic>> friendSetRemark(Map<String, dynamic> req) =>
      _sendOps('/api/FriendSetRemark', req);

  Future<Map<String, dynamic>> groupChatCreate(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatCreate', req);

  Future<Map<String, dynamic>> groupChatInfo(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatInfo', req);

  Future<Map<String, dynamic>> groupChatLeave(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatLeave', req);

  Future<Map<String, dynamic>> groupChatDissolve(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatDissolve', req);

  Future<Map<String, dynamic>> groupChatKickMember(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatKickMember', req);

  Future<Map<String, dynamic>> groupChatInviteMembers(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatInviteMembers', req);

  Future<Map<String, dynamic>> groupChatSend(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatSend', req);

  Future<Map<String, dynamic>> groupChatThreadList(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatThreadList', req);

  Future<Map<String, dynamic>> groupChatMessageList(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatMessageList', req);

  Future<Map<String, dynamic>> groupChatMarkRead(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatMarkRead', req);

  Future<Map<String, dynamic>> groupChatRecall(Map<String, dynamic> req) =>
      _sendOps('/api/GroupChatRecall', req);

  Future<Map<String, dynamic>> groupChatImagePresignPut(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/GroupChatImagePresignPut', req);

  Future<Map<String, dynamic>> groupChatImageConfirm(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/GroupChatImageConfirm', req);

  Future<Map<String, dynamic>> groupChatImagePresignGet(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/GroupChatImagePresignGet', req);

  Future<Map<String, dynamic>> groupChatVoicePresignPut(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/GroupChatVoicePresignPut', req);

  Future<Map<String, dynamic>> groupChatVoiceConfirm(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/GroupChatVoiceConfirm', req);

  Future<Map<String, dynamic>> groupChatVoicePresignGet(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/GroupChatVoicePresignGet', req);

  Future<Map<String, dynamic>> appUserLogout(Map<String, dynamic> req) =>
      _sendOps('/api/AppUserLogout', req);

  Future<Map<String, dynamic>> appUserListLoginHistoryOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserListLoginHistory', req);

  Future<String> getWsBroadcastKeyOps() async {
    final res = await _sendOps('/api/WSBroadcastKey', {});
    return res['broadcastKey']?.toString().trim() ?? '';
  }

  void setOpsBroadcastKey(String key) => _opsSdk?.setBroadcastKey(key);

  void onOpsPush(String router, PushMessageHandler handler) {
    _opsSdk?.onPush(router, handler);
  }

  void offOpsPush(String router, PushMessageHandler handler) {
    _opsSdk?.offPush(router, handler);
  }

  void setOpsOnReconnected(Future<void> Function()? callback) {
    _opsSdk?.setOnReconnected(callback);
  }

  Future<Map<String, dynamic>> signMpc(Map<String, dynamic> req) =>
      _sendOps('/api/SignMPC', req);

  // --- Shard vault / cloud backup (api_main) ---

  Future<Map<String, dynamic>> appUserSetBackupPasswordOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserSetBackupPassword', req);

  Future<Map<String, dynamic>> appUserGetBackupPasswordStatusOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserGetBackupPasswordStatus', req);

  Future<Map<String, dynamic>> appUserCheckBackupPasswordOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserCheckBackupPassword', req);

  Future<Map<String, dynamic>> appUserVerifyBackupPasswordOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserVerifyBackupPassword', req);

  Future<Map<String, dynamic>> appUserGetProfileOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserGetProfile', req);

  Future<Map<String, dynamic>> appUserUpdateProfileOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserUpdateProfile', req);

  Future<Map<String, dynamic>> appUserGetTotpConfigOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserGetTotpConfig', req);

  Future<Map<String, dynamic>> appUserBindTotpOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserBindTotp', req);

  Future<Map<String, dynamic>> appUserRebindTotpOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserRebindTotp', req);

  Future<Map<String, dynamic>> appUserVerifyTransferOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/AppUserVerifyTransfer', req);

  Future<Map<String, dynamic>> shardVaultPresignPutOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/ShardVaultPresignPut', req);

  Future<Map<String, dynamic>> shardVaultCommitUploadOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/ShardVaultCommitUpload', req);

  Future<Map<String, dynamic>> shardVaultPresignGetOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/ShardVaultPresignGet', req);

  Future<Map<String, dynamic>> shardVaultListStatusOps(
    Map<String, dynamic> req,
  ) =>
      _sendOps('/api/ShardVaultListStatus', req);
}
