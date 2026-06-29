import { API_BASES, USER_AGENT } from '../constants.js';
import { formatHashrate } from './format.js';

async function requestJson(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      Accept: 'application/json',
      'User-Agent': USER_AGENT,
      ...(options.headers || {})
    }
  });
  if (!response.ok) {
    let detail = await response.text();
    try {
      const json = JSON.parse(detail);
      detail = json.detail || json.error || detail;
    } catch {
      // keep text body
    }
    throw new Error(`HTTP ${response.status}: ${detail || response.statusText}`);
  }
  return response.json();
}

export class BTCCApiClient {
  constructor(bases = API_BASES) {
    this.bases = bases;
  }

  async fetchBalance(address) {
    const encoded = encodeURIComponent(address);
    return requestJson(`${this.bases.wallet}/api/v1/address/${encoded}/balance`);
  }

  async fetchUtxos(address) {
    const encoded = encodeURIComponent(address);
    const data = await requestJson(`${this.bases.wallet}/api/v1/address/${encoded}/utxos`);
    return data.utxos || [];
  }

  async estimateFeeRateSatVb() {
    try {
      const data = await requestJson(`${this.bases.wallet}/api/v1/fees/estimate`);
      const rate = Number(data.fee_rate_btcc_per_kvb || 0.00001);
      return Math.max(Math.trunc((rate * 1e8) / 1000), 2);
    } catch {
      return 10;
    }
  }

  async broadcast(rawtx) {
    return requestJson(`${this.bases.wallet}/api/v1/tx/broadcast`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rawtx })
    });
  }

  async fetchExplorerAddressHistory(address, { limit = 25, offset = 0 } = {}) {
    const encoded = encodeURIComponent(address);
    const url = new URL(`${this.bases.explorer}/api/v1/explorer/address/${encoded}`);
    url.searchParams.set('include_history', 'true');
    url.searchParams.set('limit', String(Math.max(1, limit)));
    url.searchParams.set('offset', String(Math.max(0, offset)));
    url.searchParams.set('summary_limit', '1000');
    url.searchParams.set('utxo_limit', '1');
    return requestJson(url.toString());
  }

  async fetchPoolStats(address, perfMode = 'Day') {
    const encoded = encodeURIComponent(address);
    return requestJson(`${this.bases.pool}/api/pplns/pools/btcc-pplns/miners/${encoded}?perfMode=${encodeURIComponent(perfMode)}`);
  }

  async fetchPoolTopMiners() {
    return requestJson(`${this.bases.pool}/api/solo/top/hashrates`);
  }

  async fetchOTCOverview() {
    return requestJson(`${this.bases.otc}/otc/api/stats/overview`, {
      headers: {
        Accept: '*/*',
        Referer: 'https://otc.btc-classic.org/otc/'
      }
    });
  }
}

export function mapPoolStats(stats) {
  const workers = stats?.performance?.workers || {};
  const totalHashrateHS = Object.values(workers).reduce((sum, w) => sum + Number(w?.hashrate || 0), 0);
  return {
    totalHashrate: formatHashrate(totalHashrateHS),
    pendingBalance: stats?.pendingBalance == null ? '—' : `${Number(stats.pendingBalance).toFixed(8)} BTCC`,
    pendingShares: stats?.pendingShares == null ? '—' : Number(stats.pendingShares).toFixed(2),
    workers: Object.entries(workers)
      .map(([name, w]) => ({
        name,
        hashrate: formatHashrate(Number(w?.hashrate || 0)),
        sps: `${Number(w?.sharesPerSecond || 0).toFixed(4)}/s`
      }))
      .sort((a, b) => Number(workers[b.name]?.hashrate || 0) - Number(workers[a.name]?.hashrate || 0)),
    samples: (stats?.performanceSamples || []).slice(-12).map((sample) => {
      const sampleWorkers = sample?.workers || {};
      const hs = Object.values(sampleWorkers).reduce((sum, w) => sum + Number(w?.hashrate || 0), 0);
      return {
        time: String(sample?.created || '—').replace('T', ' ').slice(0, 16),
        hashrate: formatHashrate(hs)
      };
    })
  };
}

function formatShare(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return '—';
  if (number >= 1_000_000_000) return `${(number / 1_000_000_000).toFixed(2)}B`;
  if (number >= 1_000_000) return `${(number / 1_000_000).toFixed(2)}M`;
  if (number >= 1_000) return `${(number / 1_000).toFixed(2)}k`;
  return number.toFixed(2);
}

export function mapTopMiners(miners) {
  return (miners || []).slice(0, 50).map((miner, index) => ({
    rank: index + 1,
    address: miner.address,
    workers: String(miner.workerCount ?? 0),
    hashrate1hr: formatHashrate(Number(miner.hashrate1hr || 0)),
    hashrate1d: formatHashrate(Number(miner.hashrate1d || 0)),
    hashrate7d: formatHashrate(Number(miner.hashrate7d || 0)),
    bestShare: formatShare(miner.bestShare)
  }));
}
