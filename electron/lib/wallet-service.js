import { amountToSats, isValidMemo } from './amount.js';
import { explorerTimeText } from './format.js';
import {
  buildSignedTx,
  createWallet,
  deriveWallet,
  normalizeMnemonic,
  normalizeRecipientAddress
} from './wallet-core.js';

function maskMnemonic(mnemonic) {
  const words = normalizeMnemonic(mnemonic).split(' ');
  if (words.length < 4) return '****';
  return `${words.slice(0, 2).join(' ')} ... ${words.slice(-2).join(' ')}`;
}

function historyAction(delta) {
  if (!delta) return '未知';
  const net = Number(delta.net_sats ?? delta.netSats ?? 0);
  const received = Number(delta.received_sats ?? delta.receivedSats ?? 0);
  const sent = Number(delta.sent_sats ?? delta.sentSats ?? 0);
  if (net > 0) return '收到';
  if (net < 0) return '转账';
  if (received > 0 && sent > 0) return '自转账';
  return '未知';
}

export class WalletService {
  constructor({ store, api }) {
    this.store = store;
    this.api = api;
    this.lastTxid = '';
    this.session = null;
  }

  clearSession() {
    this.session = null;
  }

  walletStateFromSession(statusMessage = '钱包就绪') {
    if (!this.session) return null;
    return {
      hasWallet: true,
      locked: false,
      needsMigration: false,
      address: this.session.address,
      mnemonicPreview: maskMnemonic(this.session.mnemonic),
      balanceConfirmed: this.session.balanceConfirmed || 0,
      balanceUnconfirmed: this.session.balanceUnconfirmed || 0,
      statusMessage,
      lastTxid: this.lastTxid
    };
  }

  async refreshBalanceForSession(statusMessage = '钱包就绪') {
    try {
      await this.refreshBalance();
      return this.walletStateFromSession(statusMessage);
    } catch (error) {
      return this.walletStateFromSession(`${statusMessage}，余额查询失败: ${error.message}`);
    }
  }

  async state({ refreshBalance = false } = {}) {
    if (this.session) {
      return refreshBalance ? this.refreshBalanceForSession() : this.walletStateFromSession();
    }
    const meta = this.store.metadata();
    if (!meta) {
      return {
        hasWallet: false,
        locked: false,
        needsMigration: false,
        address: '',
        mnemonicPreview: '',
        balanceConfirmed: 0,
        balanceUnconfirmed: 0,
        statusMessage: '未创建钱包',
        lastTxid: this.lastTxid
      };
    }
    return {
      hasWallet: true,
      locked: true,
      needsMigration: meta.needsMigration,
      unsupportedSafeStorage: Boolean(meta.unsupportedSafeStorage),
      address: meta.address || '',
      mnemonicPreview: meta.unsupportedSafeStorage ? '旧版本加密钱包' : meta.needsMigration ? '旧明文钱包待迁移' : '已加密',
      balanceConfirmed: 0,
      balanceUnconfirmed: 0,
      statusMessage: meta.unsupportedSafeStorage ? '旧版本加密钱包需要用助记词重新导入' : meta.needsMigration ? '旧钱包需要设置密码迁移' : '钱包已锁定',
      lastTxid: this.lastTxid
    };
  }

  async unlock(password) {
    const result = await this.store.decryptMnemonic(password);
    if (!result) throw new Error('未创建钱包');
    const wallet = deriveWallet(result.mnemonic);
    if (result.legacy) {
      await this.store.saveMnemonic({
        mnemonic: wallet.mnemonic,
        address: wallet.address,
        password,
        migratedFromLegacy: true
      });
      this.store.finishLegacyMigration();
    }
    this.session = {
      mnemonic: wallet.mnemonic,
      address: wallet.address,
      privateKey: wallet.privateKey,
      publicKey: wallet.publicKey,
      balanceConfirmed: 0,
      balanceUnconfirmed: 0
    };
    return this.refreshBalanceForSession(result.legacy ? '旧钱包已加密迁移' : '钱包已解锁');
  }

  async create({ password }) {
    const wallet = createWallet();
    await this.store.saveMnemonic({
      mnemonic: wallet.mnemonic,
      address: wallet.address,
      password
    });
    this.session = {
      mnemonic: wallet.mnemonic,
      address: wallet.address,
      privateKey: wallet.privateKey,
      publicKey: wallet.publicKey,
      balanceConfirmed: 0,
      balanceUnconfirmed: 0
    };
    const state = await this.refreshBalanceForSession('钱包已创建');
    return {
      ok: true,
      mnemonic: wallet.mnemonic,
      address: wallet.address,
      mnemonicPreview: maskMnemonic(wallet.mnemonic),
      balanceConfirmed: state.balanceConfirmed,
      balanceUnconfirmed: state.balanceUnconfirmed,
      statusMessage: state.statusMessage
    };
  }

  async import({ mnemonic, password }) {
    const wallet = deriveWallet(mnemonic);
    await this.store.saveMnemonic({
      mnemonic: wallet.mnemonic,
      address: wallet.address,
      password
    });
    this.session = {
      mnemonic: wallet.mnemonic,
      address: wallet.address,
      privateKey: wallet.privateKey,
      publicKey: wallet.publicKey,
      balanceConfirmed: 0,
      balanceUnconfirmed: 0
    };
    const state = await this.refreshBalanceForSession('钱包已导入');
    return {
      ok: true,
      address: wallet.address,
      mnemonicPreview: maskMnemonic(wallet.mnemonic),
      balanceConfirmed: state.balanceConfirmed,
      balanceUnconfirmed: state.balanceUnconfirmed,
      statusMessage: state.statusMessage
    };
  }

  exportMnemonic(password) {
    if (this.session) return this.session.mnemonic;
    throw new Error('请先解锁钱包');
  }

  lock() {
    this.clearSession();
    return { ok: true, statusMessage: '钱包已锁定' };
  }

  delete() {
    this.store.deleteWallet();
    this.lastTxid = '';
    this.clearSession();
    return { ok: true, statusMessage: '钱包已删除' };
  }

  requireSession() {
    if (!this.session) throw new Error('请先解锁钱包');
    return this.session;
  }

  async refreshBalance() {
    const wallet = this.requireSession();
    const balance = await this.api.fetchBalance(wallet.address);
    wallet.balanceConfirmed = Number(balance.confirmed || 0);
    wallet.balanceUnconfirmed = Number(balance.unconfirmed || 0);
    return {
      address: wallet.address,
      balanceConfirmed: wallet.balanceConfirmed,
      balanceUnconfirmed: wallet.balanceUnconfirmed
    };
  }

  async history({ page = 0, pageSize = 25 } = {}) {
    if (!this.session) {
      return { items: [], page: 0, pageCount: 1, total: 0, hasMore: false, nextOffset: null };
    }
    const wallet = this.session;
    const limit = Math.max(1, Math.min(Number(pageSize) || 25, 100));
    const offset = Math.max(0, Number(page) || 0) * limit;
    const data = await this.api.fetchExplorerAddressHistory(wallet.address, { limit, offset });
    const total = Number(data.tx_count ?? data.txCount ?? 0);
    const pageCount = Math.max(1, Math.ceil(total / limit));
    const items = (data.transactions || []).filter((tx) => {
      const txid = tx.tx_hash || tx.txid || tx.hash || tx.id || '';
      return Boolean(txid);
    }).map((tx) => {
      const txid = tx.tx_hash || tx.txid || tx.hash || tx.id || '';
      const delta = tx.delta || null;
      return {
        id: txid,
        txid,
        height: tx.height ?? null,
        action: historyAction(delta),
        amountSats: Number(delta?.net_sats ?? delta?.netSats ?? 0),
        timeISO: tx.time_iso || tx.timeISO || '',
        timeText: explorerTimeText(tx.time_iso || tx.timeISO || ''),
        confirmations: tx.confirmations ?? null
      };
    });
    return {
      items,
      page: Math.min(Math.max(0, Number(page) || 0), pageCount - 1),
      pageCount,
      total,
      hasMore: Boolean(data.has_more ?? data.hasMore),
      nextOffset: data.next_offset ?? data.nextOffset ?? null
    };
  }

  async send({ to, amountBTCC, memo = '' }) {
    const wallet = this.requireSession();
    const dest = normalizeRecipientAddress(to);
    const amountSats = amountToSats(amountBTCC);
    const memoText = String(memo || '').trim();
    if (!isValidMemo(memoText)) throw new Error('备注最长 80 字节');
    const [utxos, feeRate] = await Promise.all([
      this.api.fetchUtxos(wallet.address),
      this.api.estimateFeeRateSatVb()
    ]);
    const { rawtx } = buildSignedTx({
      utxos,
      recipient: dest,
      amountSats,
      changeAddress: wallet.address,
      privateKey: wallet.privateKey,
      publicKey: wallet.publicKey,
      feeRateSatVb: feeRate,
      memo: memoText
    });
    const result = await this.api.broadcast(rawtx);
    const txid = result.txid || result.hash || result.id || '';
    this.lastTxid = txid;
    await this.refreshBalance().catch(() => null);
    return {
      ok: true,
      txid,
      statusMessage: txid ? '转账成功，交易已广播' : '已广播，等待节点返回 TXID'
    };
  }
}
