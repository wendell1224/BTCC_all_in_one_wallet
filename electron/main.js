import fs from 'node:fs';
import electron from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { appPaths } from './lib/paths.js';
import { WalletStore } from './lib/wallet-store.js';
import { SettingsStore } from './lib/settings-store.js';
import { BTCCApiClient, mapPoolStats, mapTopMiners } from './lib/api-client.js';
import { WalletService } from './lib/wallet-service.js';
import { MinerRunner } from './lib/miner-runner.js';
import { timeString } from './lib/format.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const { app, BrowserWindow, clipboard, ipcMain, shell } = electron;

let mainWindow = null;
let services = null;

// Do not let Chromium/Electron touch the macOS Keychain for profile secrets.
// Wallet encryption is handled explicitly with a user password in wallet-store.js.
app.commandLine.appendSwitch('use-mock-keychain');
if (process.env.BTCC_ELECTRON_USER_DATA) {
  app.setPath('userData', process.env.BTCC_ELECTRON_USER_DATA);
}

function createServices() {
  const paths = appPaths(app);
  const api = new BTCCApiClient();
  const walletStore = new WalletStore({
    storePath: paths.walletStore,
    legacyPath: paths.legacyWalletStore
  });
  const settings = new SettingsStore(paths.settingsStore);
  const wallet = new WalletService({ store: walletStore, api });
  const miner = new MinerRunner(paths);
  miner.on('state', (state) => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('miner:state', state);
  });
  miner.on('log', (line) => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('miner:log', line);
  });
  return { paths, api, wallet, settings, miner };
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 920,
    height: 680,
    minWidth: 820,
    minHeight: 620,
    title: 'BTCC Wallet',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });
  let smokeDone = false;
  const runSmokeCheck = async (reason = 'load') => {
    if (smokeDone) return;
    smokeDone = true;
    try {
      if (process.env.BTCC_ELECTRON_SMOKE_IMAGE) {
        await new Promise((resolve) => setTimeout(resolve, 300));
        const image = await mainWindow.webContents.capturePage();
        fs.writeFileSync(process.env.BTCC_ELECTRON_SMOKE_IMAGE, image.toPNG());
      }
      const result = await mainWindow.webContents.executeJavaScript(`
        ({
          title: document.title,
          hasApi: Boolean(window.btcc && window.btcc.wallet && window.btcc.miner),
          activeTab: document.querySelector('.tab.active')?.textContent?.trim(),
          status: document.querySelector('#statusMessage')?.textContent?.trim(),
          panelCount: document.querySelectorAll('.panel').length,
          reason: ${JSON.stringify(reason)}
        })
      `);
      console.log(`[electron-smoke] ${JSON.stringify(result)}`);
      const ok = result.title === 'BTCC Wallet' && result.hasApi && result.activeTab === '钱包' && result.panelCount >= 6;
      app.exit(ok ? 0 : 1);
    } catch (error) {
      console.error(`[electron-smoke] ${error.stack || error.message}`);
      app.exit(1);
    }
  };
  const loadPromise = mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  if (process.env.BTCC_ELECTRON_SMOKE === '1') {
    mainWindow.webContents.once('did-fail-load', (_event, code, desc) => {
      console.error(`[electron-smoke] did-fail-load ${code}: ${desc}`);
      app.exit(1);
    });
    mainWindow.webContents.once('did-finish-load', () => runSmokeCheck('did-finish-load'));
    loadPromise.then(() => setTimeout(() => {
      if (!mainWindow.isDestroyed()) runSmokeCheck('loadFile');
    }, 500)).catch((error) => {
      console.error(`[electron-smoke] loadFile failed: ${error.stack || error.message}`);
      app.exit(1);
    });
    setTimeout(() => {
      console.error('[electron-smoke] timeout waiting for renderer load');
      app.exit(1);
    }, 25000).unref();
  }
}

function handle(channel, fn) {
  ipcMain.handle(channel, async (_event, payload) => {
    try {
      return { ok: true, data: await fn(payload || {}) };
    } catch (error) {
      return { ok: false, error: error.message || String(error) };
    }
  });
}

app.whenReady().then(() => {
  services = createServices();
  createWindow();

  handle('app:ready', async () => ({
    keychainAccess: false,
    paths: {
      root: services.paths.root,
      support: services.paths.support
    },
    helpers: { formatBTCC: true }
  }));
  handle('app:open-external', async (url) => {
    await shell.openExternal(String(url));
    return true;
  });
  handle('app:copy', async (text) => {
    clipboard.writeText(String(text || ''));
    return true;
  });

  handle('settings:get', async () => services.settings.getAll());
  handle('settings:update', async (patch) => services.settings.update(patch));

  handle('wallet:state', async (params) => services.wallet.state(params));
  handle('wallet:unlock', async ({ password }) => services.wallet.unlock(password));
  handle('wallet:create', async ({ password }) => services.wallet.create({ password }));
  handle('wallet:import', async ({ mnemonic, password }) => services.wallet.import({ mnemonic, password }));
  handle('wallet:export', async () => services.wallet.exportMnemonic());
  handle('wallet:lock', async () => services.wallet.lock());
  handle('wallet:delete', async () => services.wallet.delete());
  handle('wallet:balance', async () => services.wallet.refreshBalance());
  handle('wallet:history', async (params) => services.wallet.history(params));
  handle('wallet:send', async (params) => services.wallet.send(params));

  handle('market:otc', async () => {
    const overview = await services.api.fetchOTCOverview();
    return { overview, lastUpdated: timeString() };
  });
  handle('market:pool-stats', async ({ address }) => {
    const stats = await services.api.fetchPoolStats(String(address || '').trim());
    return mapPoolStats(stats);
  });
  handle('market:pool-ranking', async () => {
    const miners = await services.api.fetchPoolTopMiners();
    return { rows: mapTopMiners(miners), updatedAt: timeString() };
  });

  handle('miner:state', async () => services.miner.snapshot());
  handle('miner:start-stratum', async (settings) => services.miner.startStratum(settings));
  handle('miner:start-solo', async (settings) => services.miner.startSolo(settings));
  handle('miner:stop', async () => services.miner.stop());
  handle('miner:clear-log', async () => services.miner.clearLog());
  handle('miner:build-metal', async () => services.miner.buildMetal());
  handle('miner:smoke-test', async () => services.miner.smokeTest());
  handle('miner:proxy-test', async ({ proxy }) => services.miner.proxyTest(proxy));

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (services?.miner) services.miner.stop();
  if (process.platform !== 'darwin') app.quit();
});
