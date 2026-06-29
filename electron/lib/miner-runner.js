import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import os from 'node:os';
import { randomBytes } from 'node:crypto';
import { gpuBinary, gpuReady, seedGpuBinaryIfNeeded } from './paths.js';
import { StratumMiner, testProxyTunnel } from './stratum-node.js';
import { SoloMiner } from './solo-node.js';
import { MetalGpuHelper } from './metal-helper.js';

function appendLog(state, line) {
  state.logText += `${line}\n`;
  if (state.logText.length > 200_000) state.logText = state.logText.slice(-150_000);
  const mh = line.match(/mining ~([\d.]+) MH\/s/) || line.match(/gpu ~([\d.]+) MH\/s/);
  if (mh) state.hashrate = `${mh[1]} MH/s`;
  if (line.includes('SHARE ACCEPTED')) {
    const total = line.match(/total accepted: (\d+)/);
    if (total) state.shares = total[1];
    else state.shares = String((Number(state.shares) || 0) + 1);
  }
}

export class MinerRunner extends EventEmitter {
  constructor(paths) {
    super();
    this.paths = paths;
    seedGpuBinaryIfNeeded(paths);
    this.state = {
      logText: '',
      isRunning: false,
      isBusy: false,
      hashrate: '—',
      shares: '0',
      statusMessage: '就绪',
      gpuReady: gpuReady(paths)
    };
    this.current = null;
  }

  snapshot() {
    return { ...this.state };
  }

  emitState() {
    this.emit('state', this.snapshot());
  }

  log(line) {
    appendLog(this.state, line);
    this.emit('log', line);
    this.emitState();
  }

  clearLog() {
    this.state.logText = '';
    this.state.hashrate = '—';
    this.state.shares = '0';
    this.emitState();
    return this.snapshot();
  }

  refreshGpuStatus() {
    seedGpuBinaryIfNeeded(this.paths);
    this.state.gpuReady = gpuReady(this.paths);
    this.emitState();
    return this.state.gpuReady;
  }

  async runProcess(command, args, { cwd = this.paths.root, env = {} } = {}) {
    return new Promise((resolve) => {
      const proc = spawn(command, args, {
        cwd,
        env: { ...process.env, ...env },
        stdio: ['ignore', 'pipe', 'pipe']
      });
      proc.stdout.on('data', (chunk) => {
        for (const line of chunk.toString('utf8').split(/\r?\n/)) if (line) this.log(line);
      });
      proc.stderr.on('data', (chunk) => {
        for (const line of chunk.toString('utf8').split(/\r?\n/)) if (line) this.log(line);
      });
      proc.on('error', (error) => {
        this.log(`[错误] ${error.message}`);
        resolve({ ok: false, exitCode: -1 });
      });
      proc.on('exit', (code) => resolve({ ok: code === 0, exitCode: code ?? -1 }));
    });
  }

  async buildMetal() {
    if (this.state.isRunning || this.state.isBusy) return this.snapshot();
    this.state.isBusy = true;
    this.state.statusMessage = '编译 GPU …';
    this.emitState();
    const result = await this.runProcess('/bin/bash', [this.paths.buildMetalScript], {
      env: { GPU_BIN: this.paths.writableGpuBinary }
    });
    this.state.isBusy = false;
    this.state.gpuReady = gpuReady(this.paths);
    this.state.statusMessage = result.ok ? '编译完成' : '编译失败';
    this.emitState();
    return this.snapshot();
  }

  async smokeTest() {
    if (this.state.isRunning || this.state.isBusy) return this.snapshot();
    this.state.isBusy = true;
    this.emitState();
    let ok = false;
    try {
      const helper = new MetalGpuHelper(gpuBinary(this.paths), { onLog: (line) => this.log(line) });
      const header = Buffer.alloc(80);
      randomBytes(76).copy(header, 0);
      const result = await helper.search({
        header80: header,
        targetBe: Buffer.from('ff'.repeat(32), 'hex'),
        startNonce: 0,
        count: 1024
      });
      helper.close();
      this.log(`[test] checked=${result.checked} hashrate=${result.hashrate || 0}`);
      ok = Number(result.checked || 0) > 0;
    } catch (error) {
      this.log(`[test] FAIL: ${error.message}`);
      ok = false;
    }
    this.state.isBusy = false;
    this.state.statusMessage = ok ? 'GPU 冒烟测试通过' : 'GPU 冒烟测试失败';
    this.emitState();
    return this.snapshot();
  }

  async proxyTest(proxy) {
    if (this.state.isRunning || this.state.isBusy) return this.snapshot();
    this.state.isBusy = true;
    this.state.statusMessage = '测试代理…';
    this.emitState();
    let ok = false;
    try {
      ok = await testProxyTunnel({ proxyURL: proxy || 'socks5://127.0.0.1:7890', log: (line) => this.log(line) });
    } catch (error) {
      this.log(`[test] FAIL: ${error.message}`);
    }
    this.state.isBusy = false;
    this.state.statusMessage = ok ? '代理测试通过' : '代理测试失败';
    this.emitState();
    return this.snapshot();
  }

  async startStratum(settings) {
    if (this.state.isRunning || this.state.isBusy) return this.snapshot();
    const address = String(settings.address || '').trim();
    if (!address) {
      this.state.statusMessage = '请填写收款地址';
      this.emitState();
      return this.snapshot();
    }
    this.refreshGpuStatus();
    if (!this.state.gpuReady) {
      this.state.statusMessage = 'GPU 未编译';
      this.emitState();
      return this.snapshot();
    }
    const worker = String(settings.worker || os.hostname() || 'worker').trim();
    const user = `${address}.${worker}`;
    const miner = new StratumMiner({
      settings: { ...settings, user },
      gpuBinary: gpuBinary(this.paths),
      useGpu: true
    });
    this.current = miner;
    this.state.isBusy = false;
    this.state.isRunning = true;
    this.state.statusMessage = '启动中…';
    this.state.hashrate = '—';
    this.state.shares = '0';
    this.emitState();
    miner.on('log', (line) => this.log(line));
    miner.on('mining-status', (patch) => {
      if (patch.hashrate) this.state.hashrate = patch.hashrate;
      if (patch.shares) this.state.shares = patch.shares;
      this.emitState();
    });
    miner.on('exit', () => {
      if (this.current === miner) this.current = null;
      this.state.isRunning = false;
      this.state.statusMessage = '就绪';
      this.refreshGpuStatus();
      this.emitState();
    });
    try {
      await miner.start();
      this.state.statusMessage = '挖矿中…';
    } catch (error) {
      this.log(`[错误] 启动失败: ${error.message}`);
      miner.stop();
      this.state.isRunning = false;
      this.state.statusMessage = '启动失败';
    }
    this.emitState();
    return this.snapshot();
  }

  async startSolo(settings) {
    if (this.state.isRunning || this.state.isBusy) return this.snapshot();
    this.refreshGpuStatus();
    if (!this.state.gpuReady) {
      this.state.statusMessage = 'GPU 未编译';
      this.emitState();
      return this.snapshot();
    }
    const miner = new SoloMiner({ settings, gpuBinary: gpuBinary(this.paths) });
    this.current = miner;
    this.state.isRunning = true;
    this.state.statusMessage = '启动中…';
    this.state.hashrate = '—';
    this.emitState();
    miner.on('log', (line) => this.log(line));
    miner.on('mining-status', (patch) => {
      if (patch.hashrate) this.state.hashrate = patch.hashrate;
      this.emitState();
    });
    miner.on('exit', () => {
      if (this.current === miner) this.current = null;
      this.state.isRunning = false;
      this.state.statusMessage = '就绪';
      this.emitState();
    });
    try {
      await miner.start();
      this.state.statusMessage = '挖矿中…';
    } catch (error) {
      this.log(`[错误] 启动失败: ${error.message}`);
      miner.stop();
      this.state.isRunning = false;
      this.state.statusMessage = '启动失败';
    }
    this.emitState();
    return this.snapshot();
  }

  stop() {
    if (this.current) {
      this.log('[gui] 正在停止 …');
      this.current.stop();
      this.current = null;
    }
    this.state.isRunning = false;
    this.state.statusMessage = '就绪';
    this.emitState();
    return this.snapshot();
  }
}
