import { spawn } from 'node:child_process';
import readline from 'node:readline';

export class MetalGpuHelper {
  constructor(binary, { threadgroup = 0, perDispatch = 0, onLog = () => {} } = {}) {
    const args = ['--persistent'];
    if (threadgroup > 0) args.push('--threadgroup', String(threadgroup));
    if (perDispatch > 0) args.push('--per-dispatch', String(perDispatch));
    this.proc = spawn(binary, args, { stdio: ['pipe', 'pipe', 'pipe'] });
    this.onLog = onLog;
    this.closed = false;
    this.pending = [];
    this.rl = readline.createInterface({ input: this.proc.stdout });
    this.rl.on('line', (line) => this.handleLine(line));
    this.proc.stderr.on('data', (chunk) => {
      const text = chunk.toString('utf8');
      for (const line of text.split(/\r?\n/)) {
        if (line.trim()) this.onLog(line);
      }
    });
    this.proc.on('exit', (code) => {
      this.closed = true;
      while (this.pending.length) {
        this.pending.shift().reject(new Error(`GPU helper exited (rc=${code})`));
      }
    });
  }

  handleLine(line) {
    const item = this.pending.shift();
    if (!item) {
      this.onLog(`[gpu] unexpected output: ${line}`);
      return;
    }
    try {
      const result = JSON.parse(line);
      if (result?.error) item.reject(new Error(`GPU helper error: ${result.error}`));
      else item.resolve(result);
    } catch (error) {
      item.reject(new Error(`GPU helper bad JSON: ${error.message}`));
    }
  }

  search({ header80, targetBe, startNonce, count }) {
    if (this.closed || this.proc.exitCode !== null) {
      return Promise.reject(new Error(`GPU helper exited (rc=${this.proc.exitCode})`));
    }
    const header = Buffer.from(header80);
    const target = Buffer.from(targetBe);
    if (header.length !== 80) return Promise.reject(new Error('header80 must be 80 bytes'));
    if (target.length !== 32) return Promise.reject(new Error('target_be must be 32 bytes'));
    const request = {
      header_prefix: header.toString('hex'),
      target: target.toString('hex'),
      start_nonce: Number(startNonce) >>> 0,
      count: Number(count)
    };
    return new Promise((resolve, reject) => {
      this.pending.push({ resolve, reject });
      this.proc.stdin.write(`${JSON.stringify(request)}\n`, (error) => {
        if (error) {
          const index = this.pending.findIndex((item) => item.resolve === resolve);
          if (index >= 0) this.pending.splice(index, 1);
          reject(error);
        }
      });
    });
  }

  close() {
    this.closed = true;
    try {
      this.rl.close();
    } catch {
      // ignore
    }
    try {
      this.proc.stdin.end();
    } catch {
      // ignore
    }
    setTimeout(() => {
      if (this.proc.exitCode === null) this.proc.kill('SIGTERM');
    }, 1000).unref();
  }
}
