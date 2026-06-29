import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export function repoRoot() {
  if (process.env.BTCC_WALLET_DEV_ROOT) return process.env.BTCC_WALLET_DEV_ROOT;
  if (process.env.BTCC_MINER_DEV_ROOT) return process.env.BTCC_MINER_DEV_ROOT;
  return path.resolve(__dirname, '..', '..');
}

export function appRoot(app) {
  const devRoot = repoRoot();
  if (fs.existsSync(path.join(devRoot, 'src', 'metal_nonce_finder.mm'))) return devRoot;
  if (app?.isPackaged && process.resourcesPath) {
    return process.resourcesPath;
  }
  return devRoot;
}

export function supportDir(app) {
  if (process.env.BTCC_ELECTRON_USER_DATA) {
    fs.mkdirSync(process.env.BTCC_ELECTRON_USER_DATA, { recursive: true });
    return process.env.BTCC_ELECTRON_USER_DATA;
  }
  const base = app?.getPath ? app.getPath('appData') : path.join(os.homedir(), 'Library', 'Application Support');
  const dir = path.join(base, 'BTCCWallet');
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

export function appPaths(app) {
  const root = appRoot(app);
  const support = supportDir(app);
  return {
    root,
    support,
    srcDir: path.join(root, 'src'),
    scriptsDir: path.join(root, 'scripts'),
    testsDir: path.join(root, 'tests'),
    bundledGpuBinary: path.join(root, 'src', 'metal_nonce_finder'),
    writableGpuBinary: path.join(support, 'metal_nonce_finder'),
    buildMetalScript: path.join(root, 'scripts', 'build_metal.sh'),
    walletStore: path.join(support, 'wallet.enc.json'),
    legacyWalletStore: path.join(support, 'wallet.json'),
    settingsStore: path.join(support, 'settings.json')
  };
}

export function isExecutable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export function seedGpuBinaryIfNeeded(paths) {
  if (isExecutable(paths.writableGpuBinary)) return true;
  if (!isExecutable(paths.bundledGpuBinary)) return false;
  fs.copyFileSync(paths.bundledGpuBinary, paths.writableGpuBinary);
  fs.chmodSync(paths.writableGpuBinary, 0o755);
  return isExecutable(paths.writableGpuBinary);
}

export function gpuBinary(paths) {
  if (isExecutable(paths.bundledGpuBinary)) return paths.bundledGpuBinary;
  if (isExecutable(paths.writableGpuBinary)) return paths.writableGpuBinary;
  return paths.bundledGpuBinary;
}

export function gpuReady(paths) {
  return isExecutable(paths.bundledGpuBinary) || isExecutable(paths.writableGpuBinary);
}
