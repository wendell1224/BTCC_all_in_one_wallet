const $ = (id) => document.getElementById(id);
const api = window.btcc;

const state = {
  activeTab: 'wallet',
  settings: {},
  wallet: {
    hasWallet: false,
    address: '',
    balanceConfirmed: 0,
    balanceUnconfirmed: 0,
    statusMessage: ''
  },
  historyPage: 0,
  historyPageSize: 25,
  lastTxid: ''
};

function unwrap(result) {
  if (!result?.ok) throw new Error(result?.error || '操作失败');
  return result.data;
}

function formatBTCC(sats) {
  const n = BigInt(Math.trunc(Number(sats || 0)));
  const sign = n < 0n ? '-' : '';
  const abs = n < 0n ? -n : n;
  const whole = abs / 100000000n;
  const frac = (abs % 100000000n).toString().padStart(8, '0');
  return `${sign}${whole}.${frac} BTCC`;
}

function setText(id, text) {
  $(id).textContent = text ?? '';
}

function setValue(id, value) {
  $(id).value = value ?? '';
}

function bindInput(id, key) {
  $(id).addEventListener('change', async () => {
    state.settings[key] = $(id).value;
    await api.settings.update({ [key]: $(id).value });
  });
}

function renderMiner(miner) {
  setText('statusMessage', miner.statusMessage || '就绪');
  setText('hashrate', miner.hashrate || '—');
  setText('shares', miner.shares || '0');
  $('runIcon').className = `status-dot ${miner.isRunning ? 'running' : 'muted'}`;
  $('gpuBadge').innerHTML = `<span class="badge-dot ${miner.gpuReady ? 'ok' : 'warn'}"></span>${miner.gpuReady ? 'GPU 就绪' : 'GPU 未编译'}`;
  $('startStratum').disabled = Boolean(miner.isRunning || miner.isBusy);
  $('startSolo').disabled = Boolean(miner.isRunning || miner.isBusy);
  $('stopStratum').disabled = !miner.isRunning;
  $('stopSolo').disabled = !miner.isRunning;
  $('buildMetal').disabled = Boolean(miner.isRunning || miner.isBusy);
  $('smokeTest').disabled = Boolean(miner.isRunning || miner.isBusy);
  $('proxyTest').disabled = Boolean(miner.isRunning || miner.isBusy);
  setText('logText', miner.logText?.trim() ? miner.logText : '等待操作…');
  $('logText').scrollTop = $('logText').scrollHeight;
}

function renderWallet(wallet) {
  state.wallet = { ...state.wallet, ...wallet };
  const showCreate = !wallet.hasWallet || wallet.locked;
  $('walletCreate').classList.toggle('hidden', !showCreate);
  $('walletOverview').classList.toggle('hidden', !wallet.hasWallet || wallet.locked);
  $('walletUnlock').classList.toggle('hidden', !wallet.hasWallet || !wallet.locked || wallet.unsupportedSafeStorage);
  $('walletNewPasswordBox').classList.toggle('hidden', Boolean(wallet.hasWallet && wallet.locked && !wallet.needsMigration && !wallet.unsupportedSafeStorage));
  $('createWallet').classList.toggle('hidden', Boolean(wallet.hasWallet && wallet.locked));
  $('importMnemonic').disabled = Boolean(wallet.hasWallet && wallet.locked && !wallet.needsMigration && !wallet.unsupportedSafeStorage);
  $('importWallet').textContent = wallet.needsMigration ? '加密迁移旧钱包' : wallet.unsupportedSafeStorage ? '重新导入并加密' : '导入钱包';
  setText('walletAddress', wallet.address || '');
  setText('balanceConfirmed', formatBTCC(wallet.balanceConfirmed || 0));
  setText('balanceUnconfirmed', formatBTCC(wallet.balanceUnconfirmed || 0));
  setText('mnemonicPreview', wallet.mnemonicPreview || '');
  setText('walletStatus', wallet.statusMessage || '');
  setText('walletCreateStatus', wallet.statusMessage || '');
  state.lastTxid = wallet.lastTxid || state.lastTxid || '';
  $('txResult').classList.toggle('hidden', !state.lastTxid);
  setText('lastTxid', state.lastTxid);
}

async function loadWallet() {
  try {
    renderWallet(unwrap(await api.wallet.state()));
    await loadHistory();
  } catch (error) {
    setText('walletCreateStatus', error.message);
  }
}

async function refreshWalletBalance() {
  try {
    const balance = unwrap(await api.wallet.refreshBalance());
    renderWallet({
      ...state.wallet,
      ...balance,
      locked: false,
      hasWallet: true,
      statusMessage: '余额已刷新'
    });
  } catch (error) {
    setText('walletStatus', `余额查询失败: ${error.message}`);
  }
}

function historyAmountClass(item) {
  if (item.amountSats > 0) return 'positive';
  if (item.amountSats < 0) return 'negative';
  return 'muted';
}

async function loadHistory() {
  try {
    const info = unwrap(await api.wallet.history({ page: state.historyPage, pageSize: state.historyPageSize }));
    state.historyPage = info.page;
    setText('historyCount', `${info.total} 笔  ${info.page + 1}/${info.pageCount}`);
    $('historyPrev').disabled = info.page <= 0;
    $('historyNext').disabled = info.page + 1 >= info.pageCount;
    if (!state.wallet.hasWallet) {
      setText('historyRows', '未创建钱包');
      return;
    }
    if (state.wallet.locked) {
      setText('historyRows', '钱包已锁定');
      return;
    }
    if (!info.items.length) {
      setText('historyRows', '暂无交易记录');
      return;
    }
    $('historyRows').innerHTML = info.items.map((tx) => {
      const actionClass = tx.action === '收到' ? 'positive' : tx.action === '转账' ? 'negative' : tx.action === '自转账' ? 'warning' : 'muted';
      const amountPrefix = tx.amountSats > 0 ? '+' : '';
      return `<div class="history-row">
        <strong class="${actionClass}">${tx.action}</strong>
        <code class="${historyAmountClass(tx)}">${tx.action === '未知' ? '--' : `${amountPrefix}${formatBTCC(tx.amountSats)}`}</code>
        <code class="muted">${tx.height == null ? '未确认' : `#${tx.height}`}</code>
        <code class="muted">${tx.timeText || '—'}</code>
        <code class="selectable">${tx.txid}</code>
        <button data-open-tx="${tx.txid}">浏览</button>
      </div>`;
    }).join('');
  } catch (error) {
    setText('historyRows', `历史查询失败: ${error.message}`);
  }
}

function showBottom(tab) {
  $('bottomWallet').classList.toggle('hidden', tab !== 'wallet');
  $('bottomLog').classList.toggle('hidden', !(tab === 'pool' || tab === 'stratum'));
}

async function switchTab(tab) {
  state.activeTab = tab;
  document.querySelectorAll('.tab').forEach((btn) => btn.classList.toggle('active', btn.dataset.tab === tab));
  document.querySelectorAll('.panel').forEach((panel) => panel.classList.toggle('active', panel.id === tab));
  showBottom(tab);
  if (tab === 'otc' && !$('otcData').dataset.loaded) await refreshOtc();
  if (tab === 'pool' && !$('rankingRows').dataset.loaded) await refreshRanking();
}

function renderOtc(overview, updated) {
  $('otcEmpty').classList.add('hidden');
  $('otcData').classList.remove('hidden');
  $('otcData').dataset.loaded = '1';
  setText('otcUpdated', updated ? `更新 ${updated}` : '');
  setText('otcPrice', Number(overview.last_price ?? overview.lastPrice ?? 0).toFixed(4));
  setText('otcToken', overview.last_token ?? overview.lastToken ?? 'USDT');
  const change = Number(overview.price_change_24h ?? overview.priceChange24h ?? 0);
  $('otcChange').className = `change ${change > 0 ? 'positive' : change < 0 ? 'negative' : 'muted'}`;
  setText('otcChange', `24h ${change > 0 ? '+' : ''}${change.toFixed(2)}%`);
  setText('otcVolume', `24h 成交 ${Number(overview.volume_24h ?? overview.volume24h ?? 0).toFixed(2)} BTCC`);
  setText('otcTurnover', `成交额 ${Number(overview.volume_usdt_24h ?? overview.volumeUSDT24h ?? 0).toFixed(2)} USDT`);
  const metrics = [
    ['24h 成交笔数', overview.count_24h ?? overview.count24h ?? 0, '最近 24 小时'],
    ['总成交笔数', overview.total_count ?? overview.totalCount ?? 0, '累计订单'],
    ['24h 成交量', Number(overview.volume_24h ?? overview.volume24h ?? 0).toFixed(2), 'BTCC'],
    ['总成交量', Number(overview.total_volume ?? overview.totalVolume ?? 0).toFixed(2), 'BTCC'],
    ['24h 成交额', Number(overview.volume_usdt_24h ?? overview.volumeUSDT24h ?? 0).toFixed(2), 'USDT'],
    ['总成交额', Number(overview.volume_usdt_total ?? overview.volumeUSDTTotal ?? 0).toFixed(2), 'USDT']
  ];
  $('otcGrid').innerHTML = metrics.map(([title, value, sub]) => `<div class="metric"><div class="caption">${title}</div><div class="value">${value}</div><div class="caption">${sub}</div></div>`).join('');
}

async function refreshOtc() {
  setText('otcError', '');
  try {
    const data = unwrap(await api.market.otc());
    renderOtc(data.overview, data.lastUpdated);
  } catch (error) {
    setText('otcError', error.message);
  }
}

async function refreshPool() {
  setText('poolError', '');
  const address = $('poolAddress').value.trim();
  if (!address.startsWith('cc1')) {
    setText('poolError', '请填写 cc1 收款地址');
    return;
  }
  try {
    const data = unwrap(await api.market.poolStats(address));
    setText('poolHashrate', data.totalHashrate);
    setText('poolBalance', data.pendingBalance);
    setText('poolShares', data.pendingShares);
    $('workerRows').classList.toggle('muted', !data.workers.length);
    $('workerRows').innerHTML = data.workers.length ? data.workers.map((w) => `<div class="data-row"><span>${w.name}</span><code>${w.hashrate}</code><span class="spacer"></span><span class="caption">share ${w.sps}</span></div>`).join('') : '暂无 Worker 数据';
    $('sampleRows').classList.toggle('muted', !data.samples.length);
    $('sampleRows').innerHTML = data.samples.length ? data.samples.map((s) => `<div class="data-row"><span class="caption">${s.time}</span><span class="spacer"></span><code>${s.hashrate}</code></div>`).join('') : '暂无采样数据';
  } catch (error) {
    setText('poolError', error.message);
  }
}

async function refreshRanking() {
  setText('rankingError', '');
  try {
    const data = unwrap(await api.market.poolRanking());
    $('rankingUpdated').textContent = data.updatedAt ? `更新 ${data.updatedAt}` : '';
    $('rankingRows').dataset.loaded = '1';
    $('rankingRows').innerHTML = data.rows.length ? data.rows.map((row) => `<div class="ranking-row">
      <strong class="${row.rank === 1 ? 'warning' : ''}">${row.rank}</strong>
      <code title="${row.address}" data-copy-address="${row.address}">${row.address}</code>
      <code>${row.workers}</code><code>${row.hashrate1hr}</code><code>${row.hashrate1d}</code><code>${row.hashrate7d}</code><code>${row.bestShare}</code>
    </div>`).join('') : '<div class="ranking-row muted">暂无排行榜数据</div>';
  } catch (error) {
    setText('rankingError', error.message);
  }
}

function collectSettings() {
  const keys = ['address', 'worker', 'poolURL', 'proxy', 'suggestDifficulty', 'rpcHost', 'rpcPort', 'rpcUser', 'rpcPassword', 'soloAddress'];
  const ids = {
    address: 'mineAddress',
    worker: 'worker',
    poolURL: 'poolURL',
    proxy: 'proxy',
    suggestDifficulty: 'suggestDifficulty',
    rpcHost: 'rpcHost',
    rpcPort: 'rpcPort',
    rpcUser: 'rpcUser',
    rpcPassword: 'rpcPassword',
    soloAddress: 'soloAddress'
  };
  const next = { ...state.settings };
  for (const key of keys) next[key] = $(ids[key]).value;
  state.settings = next;
  return next;
}

async function initSettings() {
  state.settings = unwrap(await api.settings.get());
  setValue('poolAddress', state.settings.address);
  setValue('mineAddress', state.settings.address);
  setValue('worker', state.settings.worker);
  setValue('poolURL', state.settings.poolURL);
  setValue('proxy', state.settings.proxy);
  setValue('suggestDifficulty', state.settings.suggestDifficulty);
  setValue('rpcHost', state.settings.rpcHost);
  setValue('rpcPort', state.settings.rpcPort);
  setValue('rpcUser', state.settings.rpcUser);
  setValue('rpcPassword', state.settings.rpcPassword);
  setValue('soloAddress', state.settings.soloAddress);
  bindInput('mineAddress', 'address');
  bindInput('poolAddress', 'address');
  bindInput('worker', 'worker');
  bindInput('poolURL', 'poolURL');
  bindInput('proxy', 'proxy');
  bindInput('suggestDifficulty', 'suggestDifficulty');
  bindInput('rpcHost', 'rpcHost');
  bindInput('rpcPort', 'rpcPort');
  bindInput('rpcUser', 'rpcUser');
  bindInput('rpcPassword', 'rpcPassword');
  bindInput('soloAddress', 'soloAddress');
}

function bindEvents() {
  document.querySelectorAll('.tab').forEach((btn) => btn.addEventListener('click', () => switchTab(btn.dataset.tab)));
  $('createWallet').addEventListener('click', async () => {
    try {
      const password = $('newWalletPassword').value;
      const data = unwrap(await api.wallet.create(password));
      $('createdMnemonic').textContent = data.mnemonic;
      $('mnemonicDialog').showModal();
      $('newWalletPassword').value = '';
      await loadWallet();
    } catch (error) {
      setText('walletCreateStatus', error.message);
    }
  });
  $('unlockWallet').addEventListener('click', async () => {
    try {
      await api.wallet.unlock($('walletPassword').value).then(unwrap);
      $('walletPassword').value = '';
      await loadWallet();
    } catch (error) {
      setText('walletCreateStatus', error.message);
    }
  });
  $('importWallet').addEventListener('click', async () => {
    try {
      const password = state.wallet.needsMigration ? $('walletPassword').value || $('newWalletPassword').value : $('newWalletPassword').value;
      if (state.wallet.needsMigration && !$('importMnemonic').value.trim()) {
        await api.wallet.unlock(password).then(unwrap);
      } else {
        await api.wallet.import($('importMnemonic').value, password).then(unwrap);
      }
      $('importMnemonic').value = '';
      $('walletPassword').value = '';
      $('newWalletPassword').value = '';
      await loadWallet();
    } catch (error) {
      setText('walletCreateStatus', error.message);
    }
  });
  $('copyMnemonic').addEventListener('click', () => api.app.copy($('createdMnemonic').textContent));
  $('closeMnemonic').addEventListener('click', () => $('mnemonicDialog').close());
  $('copyAddress').addEventListener('click', () => api.app.copy(state.wallet.address));
  $('refreshBalance').addEventListener('click', refreshWalletBalance);
  $('deleteWallet').addEventListener('click', async () => {
    if (!confirm('确定删除本机钱包？请确认助记词已备份。')) return;
    await api.wallet.delete();
    state.lastTxid = '';
    await loadWallet();
  });
  $('lockWallet').addEventListener('click', async () => {
    await api.wallet.lock();
    await loadWallet();
  });
  $('sendTx').addEventListener('click', async () => {
    setText('walletStatus', '转账中…');
    try {
      const data = unwrap(await api.wallet.send({ to: $('sendTo').value, amountBTCC: $('sendAmount').value, memo: $('sendMemo').value }));
      state.lastTxid = data.txid || '';
      setText('walletStatus', data.statusMessage);
      $('txResult').classList.toggle('hidden', !state.lastTxid);
      setText('lastTxid', state.lastTxid);
      await loadWallet();
    } catch (error) {
      setText('walletStatus', error.message);
    }
  });
  $('copyTxid').addEventListener('click', () => api.app.copy(state.lastTxid));
  $('openTx').addEventListener('click', () => state.lastTxid && api.app.openExternal(`https://explorer.btc-classic.org/tx/${state.lastTxid}`));
  $('historyPrev').addEventListener('click', async () => {
    state.historyPage = Math.max(0, state.historyPage - 1);
    await loadHistory();
  });
  $('historyNext').addEventListener('click', async () => {
    state.historyPage += 1;
    await loadHistory();
  });
  $('historyRefresh').addEventListener('click', loadHistory);
  $('historyRows').addEventListener('click', (event) => {
    const txid = event.target?.dataset?.openTx;
    if (txid) api.app.openExternal(`https://explorer.btc-classic.org/tx/${txid}`);
  });
  $('openOtc').addEventListener('click', () => api.app.openExternal('https://otc.btc-classic.org/otc/'));
  $('refreshOtc').addEventListener('click', refreshOtc);
  $('poolUseWallet').addEventListener('click', () => {
    setValue('poolAddress', state.wallet.address || '');
  });
  $('mineUseWallet').addEventListener('click', () => {
    setValue('mineAddress', state.wallet.address || '');
  });
  $('refreshPool').addEventListener('click', refreshPool);
  $('refreshRanking').addEventListener('click', refreshRanking);
  $('rankingRows').addEventListener('click', async (event) => {
    const address = event.target?.dataset?.copyAddress;
    if (address) {
      setValue('poolAddress', address);
      setValue('mineAddress', address);
      await api.app.copy(address);
    }
  });
  $('startStratum').addEventListener('click', async () => {
    const settings = collectSettings();
    await api.settings.update(settings);
    renderMiner(unwrap(await api.miner.startStratum(settings)));
  });
  $('stopStratum').addEventListener('click', async () => renderMiner(unwrap(await api.miner.stop())));
  $('startSolo').addEventListener('click', async () => {
    const settings = collectSettings();
    await api.settings.update(settings);
    renderMiner(unwrap(await api.miner.startSolo(settings)));
  });
  $('stopSolo').addEventListener('click', async () => renderMiner(unwrap(await api.miner.stop())));
  $('buildMetal').addEventListener('click', async () => renderMiner(unwrap(await api.miner.buildMetal())));
  $('smokeTest').addEventListener('click', async () => renderMiner(unwrap(await api.miner.smokeTest())));
  $('proxyTest').addEventListener('click', async () => renderMiner(unwrap(await api.miner.proxyTest($('proxy').value))));
  $('clearLog').addEventListener('click', async () => renderMiner(unwrap(await api.miner.clearLog())));
}

async function main() {
  bindEvents();
  const appInfo = unwrap(await api.app.ready());
  setText('projectPath', appInfo.paths.root);
  await initSettings();
  renderMiner(unwrap(await api.miner.state()));
  await loadWallet();
  api.miner.onState(renderMiner);
  showBottom('wallet');
}

main().catch((error) => {
  document.body.innerHTML = `<pre style="padding:20px;color:red">${error.stack || error.message}</pre>`;
});
