import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const DEFAULTS = Object.freeze({
  address: '',
  worker: os.hostname() || 'worker',
  poolURL: 'stratum+tcp://pool.btc-classic.org:63101',
  proxy: '',
  suggestDifficulty: '-1',
  lowPowerMining: false,
  miningDutyPercent: 10,
  rpcHost: '127.0.0.1',
  rpcPort: '28476',
  rpcUser: 'user',
  rpcPassword: 'pass',
  soloAddress: ''
});

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return {};
  }
}

export class SettingsStore {
  constructor(file) {
    this.file = file;
    fs.mkdirSync(path.dirname(file), { recursive: true });
  }

  getAll() {
    return { ...DEFAULTS, ...readJson(this.file) };
  }

  update(patch) {
    const current = this.getAll();
    const next = { ...current };
    for (const key of Object.keys(DEFAULTS)) {
      if (!Object.hasOwn(patch, key)) continue;
      if (key === 'lowPowerMining') {
        next[key] = Boolean(patch[key]);
      } else if (key === 'miningDutyPercent') {
        const value = Number(patch[key]);
        next[key] = Number.isFinite(value) ? Math.min(100, Math.max(5, value)) : DEFAULTS[key];
      } else {
        next[key] = String(patch[key] ?? '');
      }
    }
    const tmp = `${this.file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
    fs.renameSync(tmp, this.file);
    try {
      fs.chmodSync(this.file, 0o600);
    } catch {
      // Best effort.
    }
    return next;
  }
}
