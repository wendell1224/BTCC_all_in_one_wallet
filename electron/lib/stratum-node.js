import { EventEmitter } from 'node:events';
import net from 'node:net';
import tls from 'node:tls';
import { URL } from 'node:url';
import { randomBytes } from 'node:crypto';
import { sha256d } from './wallet-core.js';
import { MetalGpuHelper } from './metal-helper.js';

const DIFF1_TARGET = BigInt('0x00000000FFFF0000000000000000000000000000000000000000000000000000');

export function parsePoolURL(poolURL) {
  const raw = String(poolURL || '').trim();
  const url = new URL(raw.includes('://') ? raw : `stratum+tcp://${raw}`);
  const protocol = url.protocol.replace(':', '');
  return {
    secure: protocol === 'stratum+ssl' || protocol === 'stratum+tls',
    host: url.hostname,
    port: Number(url.port || (protocol.includes('ssl') || protocol.includes('tls') ? 443 : 3333))
  };
}

export function parseProxyUrl(value) {
  if (!value) return null;
  const raw = String(value).includes('://') ? String(value) : `socks5://${value}`;
  const url = new URL(raw);
  let scheme = url.protocol.replace(':', '').toLowerCase();
  if (scheme === 'socks5h') scheme = 'socks5';
  if (scheme === 'https') scheme = 'http';
  if (!['socks5', 'http'].includes(scheme)) {
    throw new Error(`unsupported proxy scheme ${scheme} (need socks5 or http)`);
  }
  return {
    scheme,
    host: url.hostname,
    port: Number(url.port || (scheme === 'socks5' ? 1080 : 8080)),
    username: url.username ? decodeURIComponent(url.username) : '',
    password: url.password ? decodeURIComponent(url.password) : ''
  };
}

function connectSocket(host, port, timeout = 30000) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host, port });
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error(`connect timeout ${host}:${port}`));
    }, timeout);
    socket.once('connect', () => {
      clearTimeout(timer);
      resolve(socket);
    });
    socket.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function readExact(socket, n) {
  return new Promise((resolve, reject) => {
    let buf = Buffer.alloc(0);
    const cleanup = () => {
      socket.off('data', onData);
      socket.off('error', onError);
      socket.off('close', onClose);
    };
    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      if (buf.length >= n) {
        cleanup();
        const wanted = buf.subarray(0, n);
        const rest = buf.subarray(n);
        if (rest.length) socket.unshift(rest);
        resolve(wanted);
      }
    };
    const onError = (error) => {
      cleanup();
      reject(error);
    };
    const onClose = () => {
      cleanup();
      reject(new Error(`unexpected EOF (got ${buf.length}/${n} bytes)`));
    };
    socket.on('data', onData);
    socket.once('error', onError);
    socket.once('close', onClose);
  });
}

function writeAsync(socket, data) {
  return new Promise((resolve, reject) => {
    socket.write(data, (error) => (error ? reject(error) : resolve()));
  });
}

function readLine(socket, timeoutMs) {
  return new Promise((resolve, reject) => {
    let buf = Buffer.alloc(0);
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`no data within ${timeoutMs / 1000}s`));
    }, timeoutMs);
    const cleanup = () => {
      clearTimeout(timer);
      socket.off('data', onData);
      socket.off('error', onError);
      socket.off('close', onClose);
    };
    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      const idx = buf.indexOf(0x0a);
      if (idx >= 0) {
        cleanup();
        const line = buf.subarray(0, idx).toString('utf8').trim();
        const rest = buf.subarray(idx + 1);
        if (rest.length) socket.unshift(rest);
        resolve(line);
      }
    };
    const onError = (error) => {
      cleanup();
      reject(error);
    };
    const onClose = () => {
      cleanup();
      reject(new Error('connection closed before a reply arrived'));
    };
    socket.on('data', onData);
    socket.once('error', onError);
    socket.once('close', onClose);
  });
}

async function socks5Handshake(socket, targetHost, targetPort, proxy) {
  const methods = proxy.username && proxy.password ? Buffer.from([0x00, 0x02]) : Buffer.from([0x00]);
  await writeAsync(socket, Buffer.concat([Buffer.from([0x05, methods.length]), methods]));
  const rep = await readExact(socket, 2);
  if (rep[0] !== 0x05) throw new Error(`SOCKS5 bad version 0x${rep[0].toString(16)}`);
  if (rep[1] === 0xff) throw new Error('SOCKS5 proxy refused all auth methods');
  if (rep[1] === 0x02) {
    const user = Buffer.from(proxy.username || '', 'utf8');
    const pass = Buffer.from(proxy.password || '', 'utf8');
    await writeAsync(socket, Buffer.concat([Buffer.from([0x01, user.length]), user, Buffer.from([pass.length]), pass]));
    const auth = await readExact(socket, 2);
    if (auth[0] !== 0x01 || auth[1] !== 0x00) throw new Error(`SOCKS5 auth failed 0x${auth[1].toString(16)}`);
  } else if (rep[1] !== 0x00) {
    throw new Error(`SOCKS5 unsupported auth method 0x${rep[1].toString(16)}`);
  }
  const hostBytes = Buffer.from(targetHost, 'ascii');
  const portBuf = Buffer.alloc(2);
  portBuf.writeUInt16BE(targetPort);
  await writeAsync(socket, Buffer.concat([Buffer.from([0x05, 0x01, 0x00, 0x03, hostBytes.length]), hostBytes, portBuf]));
  const head = await readExact(socket, 4);
  if (head[0] !== 0x05) throw new Error(`SOCKS5 bad connect reply version 0x${head[0].toString(16)}`);
  if (head[1] !== 0x00) throw new Error(`SOCKS5 connect failed 0x${head[1].toString(16)}`);
  if (head[3] === 0x01) await readExact(socket, 6);
  else if (head[3] === 0x04) await readExact(socket, 18);
  else if (head[3] === 0x03) {
    const len = (await readExact(socket, 1))[0];
    await readExact(socket, len + 2);
  } else {
    throw new Error(`SOCKS5 unknown ATYP 0x${head[3].toString(16)}`);
  }
}

async function httpConnectHandshake(socket, targetHost, targetPort, proxy) {
  const headers = [
    `CONNECT ${targetHost}:${targetPort} HTTP/1.1`,
    `Host: ${targetHost}:${targetPort}`,
    'Proxy-Connection: keep-alive'
  ];
  if (proxy.username && proxy.password) {
    headers.push(`Proxy-Authorization: Basic ${Buffer.from(`${proxy.username}:${proxy.password}`).toString('base64')}`);
  }
  await writeAsync(socket, `${headers.join('\r\n')}\r\n\r\n`);
  let buf = Buffer.alloc(0);
  while (!buf.includes('\r\n\r\n')) {
    const chunk = await new Promise((resolve, reject) => {
      socket.once('data', resolve);
      socket.once('error', reject);
      socket.once('close', () => reject(new Error('HTTP proxy closed connection during CONNECT')));
    });
    buf = Buffer.concat([buf, chunk]);
    if (buf.length > 65536) throw new Error('HTTP proxy CONNECT response too large');
  }
  const idx = buf.indexOf('\r\n\r\n');
  const head = buf.subarray(0, idx).toString('ascii');
  const rest = buf.subarray(idx + 4);
  const statusLine = head.split('\r\n')[0];
  const code = Number(statusLine.split(' ')[1]);
  if (code < 200 || code >= 300) throw new Error(`HTTP proxy refused CONNECT: ${statusLine}`);
  if (rest.length) socket.unshift(rest);
}

async function connectViaProxy(proxy, targetHost, targetPort, timeout) {
  const socket = await connectSocket(proxy.host, proxy.port, timeout);
  if (proxy.scheme === 'socks5') await socks5Handshake(socket, targetHost, targetPort, proxy);
  else await httpConnectHandshake(socket, targetHost, targetPort, proxy);
  return socket;
}

export async function testProxyTunnel({
  proxyURL,
  targetHost = 'pool.btc-classic.org',
  targetPort = 63101,
  timeout = 15000,
  log = () => {}
}) {
  const proxy = parseProxyUrl(proxyURL || 'socks5://127.0.0.1:7890');
  log(`[test] proxy : ${proxyURL || 'socks5://127.0.0.1:7890'}`);
  log(`[test] target: ${targetHost}:${targetPort}`);
  log(`[test] parsed proxy: ${proxy.scheme}://${proxy.host}:${proxy.port}`);
  log('[test] opening tunnel ...');
  const t0 = Date.now();
  const socket = await connectViaProxy(proxy, targetHost, targetPort, timeout);
  try {
    log(`[test] tunnel up in ${((Date.now() - t0) / 1000).toFixed(2)}s`);
    const req = JSON.stringify({ id: 1, method: 'mining.subscribe', params: ['proxy-test/0.1'] }) + '\n';
    await writeAsync(socket, req);
    log('[test] sent mining.subscribe, waiting for reply ...');
    const line = await readLine(socket, 10000);
    log(`[test] OK: got first line`);
    log(`[test] first line: ${line.slice(0, 200)}`);
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (error) {
      throw new Error(`reply is not JSON (${error.message})`);
    }
    if (!msg.result) {
      throw new Error(`JSON received but no result: ${JSON.stringify(msg)}`);
    }
    log('[test] PASS: mining.subscribe succeeded through proxy');
    return true;
  } finally {
    socket.destroy();
  }
}

function toUInt32LE(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(Number(n) >>> 0);
  return b;
}

export function stratumPrevhashToLe32(prevHex) {
  const b = Buffer.from(prevHex, 'hex');
  if (b.length !== 32) throw new Error(`prev hex must be 32 bytes, got ${b.length}`);
  const out = [];
  for (let i = 0; i < 32; i += 4) out.push(Buffer.from(b.subarray(i, i + 4)).reverse());
  return Buffer.concat(out);
}

export function diffToTarget(diff) {
  const d = Number(diff);
  if (d <= 0) return (1n << 256n) - 1n;
  const scale = 1_000_000n;
  return (DIFF1_TARGET * scale) / BigInt(Math.max(1, Math.floor(d * Number(scale))));
}

export function submitNonceHex(nonce) {
  return (Number(nonce) >>> 0).toString(16).padStart(8, '0');
}

export function buildJob(params) {
  const [jobId, prevhashHex, cb1Hex, cb2Hex, merkleBranches, versionHex, nbitsHex, ntimeHex, cleanJobs] = params;
  return {
    jobId,
    prevLe32: stratumPrevhashToLe32(prevhashHex),
    coinbase1: Buffer.from(cb1Hex, 'hex'),
    coinbase2: Buffer.from(cb2Hex, 'hex'),
    merkleBranchLe: (merkleBranches || []).map((h) => Buffer.from(h, 'hex')),
    versionLe: toUInt32LE(Number.parseInt(versionHex, 16)),
    nbitsLe: toUInt32LE(Number.parseInt(nbitsHex, 16)),
    ntimeLe: toUInt32LE(Number.parseInt(ntimeHex, 16)),
    cleanJobs: Boolean(cleanJobs)
  };
}

function merkleRootLe(coinbaseTxidLe, branchesLe) {
  let root = coinbaseTxidLe;
  for (const branch of branchesLe) root = Buffer.from(sha256d(Buffer.concat([root, branch])));
  return root;
}

export function buildBlockHeader({ job, coinbase, nonce, ntimeOverride }) {
  const cbTxidLe = Buffer.from(sha256d(coinbase));
  const mrLe = merkleRootLe(cbTxidLe, job.merkleBranchLe);
  const ntimeBytes = ntimeOverride == null ? job.ntimeLe : toUInt32LE(ntimeOverride);
  return Buffer.concat([job.versionLe, job.prevLe32, mrLe, ntimeBytes, job.nbitsLe, toUInt32LE(nonce)]);
}

function randomUInt32() {
  return randomBytes(4).readUInt32LE(0);
}

function expectedShareSeconds(diff, hashrate) {
  if (diff <= 0 || hashrate <= 0) return null;
  return (diff * 4294967296.0) / hashrate;
}

function formatDuration(seconds) {
  if (seconds == null) return '?';
  if (seconds < 60) return `${seconds.toFixed(0)}s`;
  if (seconds < 3600) return `${(seconds / 60).toFixed(1)}m`;
  if (seconds < 86400) return `${(seconds / 3600).toFixed(1)}h`;
  return `${(seconds / 86400).toFixed(1)}d`;
}

export class StratumMiner extends EventEmitter {
  constructor({ settings, gpuBinary, useGpu = true }) {
    super();
    this.settings = settings;
    this.gpuBinary = gpuBinary;
    this.useGpu = useGpu;
    this.socket = null;
    this.helper = null;
    this.connected = false;
    this.nextId = 1;
    this.pending = new Map();
    this.recv = '';
    this.state = {
      extranonce1: Buffer.alloc(0),
      extranonce2Size: 4,
      difficulty: 1,
      currentJob: null,
      newJob: false
    };
    this.accepted = 0;
    this.rejected = 0;
    this.stopped = false;
  }

  log(line) {
    this.emit('log', line);
  }

  async start() {
    const parsed = parsePoolURL(this.settings.poolURL);
    const proxy = parseProxyUrl(this.settings.proxy || '');
    const via = proxy ? ` via ${proxy.scheme}://${proxy.host}:${proxy.port}` : '';
    this.log(`[stratum] connecting to ${parsed.host}:${parsed.port}${via} as '${this.settings.user}' ...`);
    let socket = proxy
      ? await connectViaProxy(proxy, parsed.host, parsed.port, 30000)
      : await connectSocket(parsed.host, parsed.port, 30000);
    if (parsed.secure) {
      socket = tls.connect({ socket, servername: parsed.host });
      await new Promise((resolve, reject) => {
        socket.once('secureConnect', resolve);
        socket.once('error', reject);
      });
    }
    this.socket = socket;
    this.connected = true;
    socket.setKeepAlive(true, 30000);
    socket.on('data', (chunk) => this.handleData(chunk));
    socket.on('close', () => {
      this.connected = false;
      this.emit('exit', { reason: 'disconnect' });
    });
    socket.on('error', (error) => this.log(`[stratum] socket error: ${error.message}`));

    if (this.useGpu) {
      this.helper = new MetalGpuHelper(this.gpuBinary, { onLog: (line) => this.log(line) });
    }

    const sub = await this.call('mining.subscribe', ['btcc-electron-miner/0.1'], 15000);
    const [_ignored, ex1Hex, ex2Size] = sub;
    this.state.extranonce1 = Buffer.from(ex1Hex, 'hex');
    this.state.extranonce2Size = Number(ex2Size);
    this.log(`[stratum] subscribed: extranonce1=${ex1Hex} extranonce2_size=${ex2Size}`);

    let suggest = Number(this.settings.suggestDifficulty ?? -1);
    if (suggest < 0) {
      suggest = 16;
      this.log(`[stratum] auto suggest_difficulty=${suggest} (node)`);
    }
    if (suggest > 0) {
      const accepted = await this.call('mining.suggest_difficulty', [suggest], 10000).catch((e) => {
        this.log(`[stratum] suggest_difficulty error: ${e.message}`);
        return false;
      });
      this.log(accepted ? `[stratum] suggest_difficulty accepted by pool: ${suggest}` : `[stratum] suggest_difficulty not accepted`);
    }

    const auth = await this.call('mining.authorize', [this.settings.user, 'x'], 15000);
    if (!auth) throw new Error(`authorize failed: ${auth}`);
    this.log(`[stratum] authorized as '${this.settings.user}'`);
    this.emit('status', { running: true, message: '挖矿中…' });
    this.mineLoop().catch((error) => {
      if (!this.stopped) this.log(`[stratum] miner error: ${error.message}`);
      this.stop();
    });
  }

  handleData(chunk) {
    this.recv += chunk.toString('utf8');
    for (;;) {
      const idx = this.recv.indexOf('\n');
      if (idx < 0) break;
      const line = this.recv.slice(0, idx).trim();
      this.recv = this.recv.slice(idx + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (error) {
        this.log(`[stratum] bad JSON line: ${line.slice(0, 200)} (${error.message})`);
        continue;
      }
      if (msg.id != null && ('result' in msg || 'error' in msg)) {
        const pending = this.pending.get(msg.id);
        if (pending) {
          this.pending.delete(msg.id);
          if (msg.error) pending.reject(new Error(JSON.stringify(msg.error)));
          else pending.resolve(msg.result);
        }
      } else {
        this.handleNotification(msg.method, msg.params || []);
      }
    }
  }

  handleNotification(method, params) {
    if (method === 'mining.set_difficulty') {
      this.state.difficulty = Number(params[0]);
      this.log(`[stratum] set_difficulty=${this.state.difficulty}`);
    } else if (method === 'mining.notify') {
      try {
        const job = buildJob(params);
        this.state.currentJob = job;
        this.state.newJob = true;
        this.log(`[stratum] new job ${job.jobId} prev=${String(params[1]).slice(0, 16)}.. clean=${job.cleanJobs}`);
      } catch (error) {
        this.log(`[stratum] bad notify: ${error.message}`);
      }
    } else if (method === 'mining.set_extranonce') {
      this.state.extranonce1 = Buffer.from(params[0], 'hex');
      this.state.extranonce2Size = Number(params[1]);
      this.log(`[stratum] set_extranonce: ex1=${this.state.extranonce1.toString('hex')} ex2_size=${this.state.extranonce2Size}`);
    } else if (method === 'client.reconnect') {
      this.log(`[stratum] pool asked us to reconnect: ${JSON.stringify(params)}`);
      this.stop();
    } else if (method === 'client.show_message') {
      this.log(`[stratum] pool message: ${JSON.stringify(params)}`);
    } else {
      this.log(`[stratum] unhandled notification ${JSON.stringify(method)} ${JSON.stringify(params)}`);
    }
  }

  call(method, params, timeoutMs) {
    if (!this.socket || !this.connected) return Promise.reject(new Error('not connected'));
    const id = this.nextId++;
    const payload = JSON.stringify({ id, method, params }) + '\n';
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`no response to '${method}' within ${timeoutMs / 1000}s`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        }
      });
      this.socket.write(payload, (error) => {
        if (error) {
          clearTimeout(timer);
          this.pending.delete(id);
          reject(error);
        }
      });
    });
  }

  async mineLoop() {
    let extranonce2Counter = randomUInt32();
    let startedAt = Date.now();
    let lastStatus = 0;
    let curGpuBatch = 1 << 24;
    const targetBatchSeconds = 2.0;
    while (!this.stopped && this.connected) {
      const job = this.state.currentJob;
      const diff = this.state.difficulty;
      if (!job || diff <= 0) {
        await new Promise((resolve) => setTimeout(resolve, 200));
        continue;
      }
      extranonce2Counter = (extranonce2Counter + 1) >>> 0;
      const ex2 = Buffer.alloc(this.state.extranonce2Size);
      let ex2Value = BigInt(extranonce2Counter);
      for (let i = 0; i < ex2.length; i += 1) {
        ex2[i] = Number(ex2Value & 0xffn);
        ex2Value >>= 8n;
      }
      const coinbase = Buffer.concat([job.coinbase1, this.state.extranonce1, ex2, job.coinbase2]);
      const target = diffToTarget(diff);
      const targetBe = Buffer.from(target.toString(16).padStart(64, '0'), 'hex');
      const localNtime = Math.max(Math.floor(Date.now() / 1000), job.ntimeLe.readUInt32LE(0));
      const headerTemplate = buildBlockHeader({ job, coinbase, nonce: 0, ntimeOverride: localNtime });
      const startNonce = randomUInt32();
      const res = await this.helper.search({
        header80: headerTemplate,
        targetBe,
        startNonce,
        count: curGpuBatch
      });
      const checked = Number(res.checked || 0);
      const elapsedMs = Number(res.elapsed_ms || 0);
      const hashrate = Number(res.hashrate || (checked && elapsedMs ? checked * 1000 / elapsedMs : 0));
      if (checked > 0 && elapsedMs > 0) {
        const desired = Math.max(1 << 22, Math.min(Math.trunc(hashrate * targetBatchSeconds), 1 << 30));
        curGpuBatch = Math.trunc((curGpuBatch * 3 + desired) / 4);
      }
      const now = Date.now();
      if (now - lastStatus >= 5000) {
        const avgShare = formatDuration(expectedShareSeconds(diff, hashrate));
        const mh = (hashrate / 1e6).toFixed(1);
        const uptime = Math.trunc((now - startedAt) / 1000);
        this.log(`[stratum] mining ~${mh} MH/s  diff=${diff}  avg_share=${avgShare}  shares=${this.accepted}  uptime=${uptime}s  job=${job.jobId} ex2=${ex2.toString('hex')}`);
        this.emit('mining-status', { hashrate: `${mh} MH/s`, shares: String(this.accepted) });
        lastStatus = now;
      }
      if (!res.found) {
        this.state.newJob = false;
        continue;
      }
      const nonce = Number(res.nonce) >>> 0;
      const headerFull = Buffer.concat([headerTemplate.subarray(0, 76), toUInt32LE(nonce)]);
      const hBe = Buffer.from(sha256d(headerFull)).reverse();
      if (BigInt(`0x${hBe.toString('hex')}`) > target) {
        this.log(`[stratum] !! local verify failed for share nonce=${nonce}`);
        continue;
      }
      const ntimeHex = localNtime.toString(16).padStart(8, '0');
      const nonceHex = submitNonceHex(nonce);
      this.log(`[stratum] share candidate  job=${job.jobId} diff=${diff} ex2=${ex2.toString('hex')} ntime=${ntimeHex} nonce=${nonceHex} nonce_int=${nonce} hash=${hBe.toString('hex')} target=${targetBe.toString('hex')}`);
      const submit = await this.call('mining.submit', [this.settings.user, job.jobId, ex2.toString('hex'), ntimeHex, nonceHex], 20000)
        .catch((error) => ({ error: error.message }));
      if (submit === true) {
        this.accepted += 1;
        this.log(`[stratum] SHARE ACCEPTED  job=${job.jobId} nonce=${nonceHex} hash=${hBe.toString('hex')}  (total accepted: ${this.accepted})`);
        this.emit('mining-status', { shares: String(this.accepted) });
      } else {
        this.rejected += 1;
        this.log(`[stratum] share rejected  job=${job.jobId} nonce=${nonceHex}  reason=${JSON.stringify(submit)}  (total rejected: ${this.rejected})`);
      }
    }
  }

  stop() {
    this.stopped = true;
    this.connected = false;
    for (const [, pending] of this.pending) pending.reject(new Error('miner stopped'));
    this.pending.clear();
    if (this.helper) {
      this.helper.close();
      this.helper = null;
    }
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
  }
}
