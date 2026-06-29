import { EventEmitter } from 'node:events';
import { request as httpRequest } from 'node:http';
import { randomBytes } from 'node:crypto';
import { sha256d } from './wallet-core.js';
import { MetalGpuHelper } from './metal-helper.js';
import { gpuThrottleSleepMs, normalizeGpuDutyPercent } from './stratum-node.js';

function varint(n) {
  const value = Number(n);
  if (value < 0xfd) return Buffer.from([value]);
  if (value <= 0xffff) {
    const b = Buffer.alloc(3);
    b[0] = 0xfd;
    b.writeUInt16LE(value, 1);
    return b;
  }
  if (value <= 0xffffffff) {
    const b = Buffer.alloc(5);
    b[0] = 0xfe;
    b.writeUInt32LE(value, 1);
    return b;
  }
  const b = Buffer.alloc(9);
  b[0] = 0xff;
  b.writeBigUInt64LE(BigInt(value), 1);
  return b;
}

function uint32LE(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(Number(n) >>> 0);
  return b;
}

function uint64LE(n) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(n));
  return b;
}

function serUint256LeFromHexBe(hex) {
  const b = Buffer.from(hex, 'hex');
  if (b.length !== 32) throw new Error('expected 32-byte hex');
  return Buffer.from(b).reverse();
}

export function compactToTarget(nbits) {
  const exp = (Number(nbits) >> 24) & 0xff;
  const mant = Number(nbits) & 0x007fffff;
  if (Number(nbits) & 0x00800000) throw new Error('negative compact');
  if (exp <= 3) return BigInt(mant >> (8 * (3 - exp)));
  return BigInt(mant) << BigInt(8 * (exp - 3));
}

function serializeScriptnum(value) {
  if (value === 0) return Buffer.alloc(0);
  const neg = value < 0;
  let abs = neg ? (~BigInt(value) + 1n) & 0xffffffffffffffffn : BigInt(value);
  const out = [];
  while (abs) {
    out.push(Number(abs & 0xffn));
    abs >>= 8n;
  }
  if (out[out.length - 1] & 0x80) out.push(neg ? 0x80 : 0x00);
  else if (neg) out[out.length - 1] |= 0x80;
  return Buffer.from(out);
}

function scriptPush(data) {
  const b = Buffer.from(data);
  if (b.length < 0x4c) return Buffer.concat([Buffer.from([b.length]), b]);
  if (b.length <= 0xff) return Buffer.concat([Buffer.from([0x4c, b.length]), b]);
  if (b.length <= 0xffff) {
    const len = Buffer.alloc(3);
    len[0] = 0x4d;
    len.writeUInt16LE(b.length, 1);
    return Buffer.concat([len, b]);
  }
  const len = Buffer.alloc(5);
  len[0] = 0x4e;
  len.writeUInt32LE(b.length, 1);
  return Buffer.concat([len, b]);
}

function encodeScriptInt64(n) {
  if (n === 0) return Buffer.from([0x00]);
  if (n >= 1 && n <= 16) return Buffer.from([0x50 + n]);
  return scriptPush(serializeScriptnum(n));
}

export function merkleRootLe(txidsLe) {
  if (!txidsLe.length) return Buffer.alloc(32);
  let level = txidsLe.slice();
  while (level.length > 1) {
    if (level.length % 2 === 1) level.push(level[level.length - 1]);
    const next = [];
    for (let i = 0; i < level.length; i += 2) {
      next.push(Buffer.from(sha256d(Buffer.concat([level[i], level[i + 1]]))));
    }
    level = next;
  }
  return level[0];
}

export function buildCoinbaseTx({ height, coinbaseValue, payoutScript, extranonce, witnessCommitmentScript }) {
  const version = 2;
  const scriptSig = Buffer.concat([encodeScriptInt64(height), Buffer.from([0x00]), scriptPush(extranonce)]);
  const vin = Buffer.concat([
    Buffer.alloc(32),
    uint32LE(0xffffffff),
    varint(scriptSig.length),
    scriptSig,
    uint32LE(0xffffffff)
  ]);
  const outputs = [
    Buffer.concat([uint64LE(coinbaseValue), varint(payoutScript.length), payoutScript])
  ];
  if (witnessCommitmentScript) {
    outputs.push(Buffer.concat([uint64LE(0), varint(witnessCommitmentScript.length), witnessCommitmentScript]));
  }
  const vout = Buffer.concat([varint(outputs.length), ...outputs]);
  const witness = Buffer.concat([varint(1), varint(32), Buffer.alloc(32)]);
  const txWitness = Buffer.concat([
    uint32LE(version),
    Buffer.from([0x00, 0x01]),
    varint(1),
    vin,
    vout,
    witness,
    uint32LE(0)
  ]);
  const txNoWitness = Buffer.concat([uint32LE(version), varint(1), vin, vout, uint32LE(0)]);
  return {
    tx: txWitness,
    txidLe: Buffer.from(sha256d(txNoWitness))
  };
}

function buildBlock({ version, prevhashHex, merkleRoot, ntime, nbitsHex, nonce, txs }) {
  const header = Buffer.concat([
    uint32LE(version),
    serUint256LeFromHexBe(prevhashHex),
    merkleRoot,
    uint32LE(ntime),
    uint32LE(Number.parseInt(nbitsHex, 16)),
    uint32LE(nonce)
  ]);
  return Buffer.concat([header, varint(txs.length), ...txs]);
}

function rpcCall({ host, port, user, password, timeout, path = '/', method, params = [] }) {
  const body = JSON.stringify({ jsonrpc: '1.0', id: 'gbt-miner', method, params });
  const auth = Buffer.from(`${user}:${password}`).toString('base64');
  return new Promise((resolve, reject) => {
    const req = httpRequest({
      host,
      port,
      path,
      method: 'POST',
      timeout,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
        Authorization: `Basic ${auth}`,
        'User-Agent': 'btcc-electron-gbt/0.1'
      }
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let decoded;
        try {
          decoded = JSON.parse(text);
        } catch (error) {
          reject(new Error(`HTTP ${res.statusCode}: failed to parse JSON (${error.message}): ${text.slice(0, 200)}`));
          return;
        }
        if (decoded.error) {
          const err = new Error(decoded.error.message || 'RPC error');
          err.code = decoded.error.code;
          reject(err);
          return;
        }
        if (res.statusCode !== 200) {
          reject(new Error(`HTTP ${res.statusCode}: ${text.slice(0, 200)}`));
          return;
        }
        resolve(decoded.result);
      });
    });
    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy(new Error(`RPC timeout calling ${method}`));
    });
    req.end(body);
  });
}

async function ensureWallet(settings) {
  const walletName = 'miner';
  const walletPath = `/wallet/${walletName}`;
  try {
    const loaded = await rpcCall({ ...settings, path: '/', method: 'listwallets' });
    if (loaded.includes(walletName)) {
      await rpcCall({ ...settings, path: walletPath, method: 'getwalletinfo' });
      return walletPath;
    }
  } catch {
    // Let the wallet RPC call below surface the real error if wallets are unsupported.
  }
  let exists = false;
  try {
    const dir = await rpcCall({ ...settings, path: '/', method: 'listwalletdir' });
    exists = Boolean((dir.wallets || []).find((w) => w.name === walletName));
  } catch {
    exists = false;
  }
  if (exists) {
    await rpcCall({ ...settings, path: '/', method: 'loadwallet', params: [walletName] });
  } else {
    await rpcCall({
      ...settings,
      path: '/',
      method: 'createwallet',
      params: [walletName, false, false, '', false, true, true]
    });
  }
  await rpcCall({ ...settings, path: walletPath, method: 'getwalletinfo' });
  return walletPath;
}

async function pickPayoutScript(settings, walletPath, address, log) {
  if (address) {
    const info = await rpcCall({ ...settings, path: '/', method: 'validateaddress', params: [address] });
    if (!info.isvalid) throw new Error(`Solo 收款地址无效: ${address}`);
    log(`[miner] Using provided address: ${address}`);
    log(`[miner] scriptPubKey: ${info.scriptPubKey}`);
    return { address, script: Buffer.from(info.scriptPubKey, 'hex') };
  }
  const addr = await rpcCall({ ...settings, path: walletPath, method: 'getnewaddress', params: ['mining', 'bech32'] });
  const info = await rpcCall({ ...settings, path: '/', method: 'validateaddress', params: [addr] });
  log('[miner] No address provided; created a new address via getnewaddress');
  log(`[miner] address: ${addr}`);
  log(`[miner] scriptPubKey: ${info.scriptPubKey}`);
  return { address: addr, script: Buffer.from(info.scriptPubKey, 'hex') };
}

export class SoloMiner extends EventEmitter {
  constructor({ settings, gpuBinary }) {
    super();
    this.settings = {
      host: settings.rpcHost,
      port: Number(settings.rpcPort),
      user: settings.rpcUser,
      password: settings.rpcPassword,
      timeout: 10000
    };
    this.address = String(settings.soloAddress || '').trim();
    this.dutyPercent = normalizeGpuDutyPercent(settings);
    this.gpuBinary = gpuBinary;
    this.stopped = false;
    this.helper = null;
  }

  log(line) {
    this.emit('log', line);
  }

  async start() {
    this.helper = new MetalGpuHelper(this.gpuBinary, { onLog: (line) => this.log(line) });
    const walletPath = await ensureWallet(this.settings);
    const payout = await pickPayoutScript(this.settings, walletPath, this.address, (line) => this.log(line));
    this.log(`[miner] RPC endpoint: http://${this.settings.host}:${this.settings.port}`);
    this.log('[miner] Wallet: miner');
    this.log(`[miner] Mining payout: ${payout.address}`);
    if (this.dutyPercent < 100) {
      this.log(`[miner] low-power online mode: GPU duty ${this.dutyPercent}%`);
    }
    this.emit('status', { running: true, message: '挖矿中…' });
    this.mineLoop(payout).catch((error) => {
      if (!this.stopped) this.log(`[miner] error: ${error.message}`);
      this.stop();
    });
  }

  async mineLoop(payout) {
    let curGpuBatch = 1 << 25;
    const targetBatchSeconds = this.dutyPercent < 100 ? 0.25 : 2.0;
    let lastPrev = '';
    while (!this.stopped) {
      let tmpl;
      try {
        tmpl = await rpcCall({ ...this.settings, path: '/', method: 'getblocktemplate', params: [{ rules: ['segwit'] }] });
      } catch (error) {
        const msg = String(error.message || '').toLowerCase();
        if ([-10, -28].includes(error.code) || msg.includes('initial') || msg.includes('downloading') || msg.includes('verifying')) {
          this.log(`[miner] Node not ready (${error.message}); retrying in 30s`);
          await new Promise((resolve) => setTimeout(resolve, 30000));
          continue;
        }
        throw error;
      }
      const prev = tmpl.previousblockhash;
      const height = Number(tmpl.height);
      const version = Number(tmpl.version);
      const coinbaseValue = Number(tmpl.coinbasevalue);
      const nbitsHex = tmpl.bits;
      const nbits = Number.parseInt(nbitsHex, 16);
      const target = compactToTarget(nbits);
      const mintime = Number(tmpl.mintime || 0);
      let ntime = Math.max(Number(tmpl.curtime), Math.floor(Date.now() / 1000), mintime);
      const witnessCommitmentScript = tmpl.default_witness_commitment ? Buffer.from(tmpl.default_witness_commitment, 'hex') : null;
      if (prev !== lastPrev) {
        this.log(`[miner] New template: height=${height} prev=${prev.slice(0, 16)}.. bits=${nbitsHex} coinbase=${coinbaseValue}`);
        lastPrev = prev;
      }
      const txs = (tmpl.transactions || []).map((tx) => Buffer.from(tx.data, 'hex'));
      const txidsLe = (tmpl.transactions || []).map((tx) => serUint256LeFromHexBe(tx.txid));
      const extranoncePrefix = Buffer.concat([uint32LE(process.pid), randomBytes(4)]);
      let extranonceCounter = 0;
      let refetch = false;
      while (!this.stopped) {
        const extranonce = Buffer.concat([extranoncePrefix, uint32LE(extranonceCounter)]);
        const coinbase = buildCoinbaseTx({
          height,
          coinbaseValue,
          payoutScript: payout.script,
          extranonce,
          witnessCommitmentScript
        });
        const allTxs = [coinbase.tx, ...txs];
        const mrLe = merkleRootLe([coinbase.txidLe, ...txidsLe]);
        const targetBe = Buffer.from(target.toString(16).padStart(64, '0'), 'hex');
        let totalChecked = 0;
        const t0 = Date.now();
        const startNonce = randomBytes(4).readUInt32LE(0);
        while (!this.stopped) {
          ntime = Math.max(ntime, Math.floor(Date.now() / 1000), mintime);
          const headerTemplate = Buffer.concat([
            uint32LE(version),
            serUint256LeFromHexBe(prev),
            mrLe,
            uint32LE(ntime),
            uint32LE(nbits),
            Buffer.alloc(4)
          ]);
          const remaining = 2 ** 32 - totalChecked;
          if (remaining <= 0) {
            this.log('[miner] Exhausted 32-bit nonce space; bumping extranonce');
            break;
          }
          const batchSize = Math.min(curGpuBatch, remaining);
          const batchStart = (startNonce + totalChecked) >>> 0;
          const result = await this.helper.search({ header80: headerTemplate, targetBe, startNonce: batchStart, count: batchSize });
          totalChecked += batchSize;
          const hr = Number(result.hashrate || 0);
          if (hr > 0) {
            const desired = Math.max(1 << 22, Math.min(Math.trunc(hr * targetBatchSeconds), 1 << 30));
            curGpuBatch = Math.trunc((curGpuBatch * 3 + desired) / 4);
          }
          const throttleMs = !result.found
            ? gpuThrottleSleepMs({ dutyPercent: this.dutyPercent, elapsedMs: Number(result.elapsed_ms || 0) })
            : 0;
          if (throttleMs > 0) await new Promise((resolve) => setTimeout(resolve, throttleMs));
          const dt = Math.max((Date.now() - t0) / 1000, 1e-6);
          const effectiveHashrate = totalChecked / dt;
          this.log(`[miner] gpu ~${(hr / 1e6).toFixed(2)} MH/s (effective ${(effectiveHashrate / 1e6).toFixed(2)} MH/s) height=${height} ext=${extranonceCounter} checked=${totalChecked}`);
          this.emit('mining-status', { hashrate: `${(effectiveHashrate / 1e6).toFixed(2)} MH/s` });
          if (result.found) {
            const nonce = Number(result.nonce) >>> 0;
            const headerFull = Buffer.concat([
              uint32LE(version),
              serUint256LeFromHexBe(prev),
              mrLe,
              uint32LE(ntime),
              uint32LE(nbits),
              uint32LE(nonce)
            ]);
            const hBeHex = Buffer.from(sha256d(headerFull)).reverse().toString('hex');
            if (BigInt(`0x${hBeHex}`) > target) {
              this.log(`[miner] !! GPU returned nonce=${nonce} but CPU verify says hash > target (hash=${hBeHex}); skipping`);
              continue;
            }
            const block = buildBlock({ version, prevhashHex: prev, merkleRoot: mrLe, ntime, nbitsHex, nonce, txs: allTxs });
            this.log(`[miner] FOUND block hash=${hBeHex} nonce=${nonce} extranonce=${extranonceCounter}`);
            const res = await rpcCall({ ...this.settings, path: '/', method: 'submitblock', params: [block.toString('hex')] });
            if (res == null) this.log('[miner] submitblock: accepted (primary)');
            else this.log(`[miner] submitblock (primary) returned: ${res}`);
            refetch = true;
            break;
          }
          try {
            const best = await rpcCall({ ...this.settings, path: '/', method: 'getbestblockhash' });
            if (best !== prev) {
              this.log('[miner] Tip changed; discarding stale work');
              refetch = true;
              break;
            }
          } catch {
            // Ignore transient polling errors.
          }
        }
        if (refetch) break;
        extranonceCounter += 1;
        if (extranonceCounter > 5000) {
          this.log('[miner] Extranonce rollover; refetching template');
          break;
        }
      }
    }
  }

  stop() {
    this.stopped = true;
    if (this.helper) {
      this.helper.close();
      this.helper = null;
    }
    this.emit('exit', { reason: 'stopped' });
  }
}
