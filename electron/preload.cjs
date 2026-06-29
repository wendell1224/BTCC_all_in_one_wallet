const { contextBridge, ipcRenderer } = require('electron');

const invoke = (channel, payload) => ipcRenderer.invoke(channel, payload);

contextBridge.exposeInMainWorld('btcc', {
  app: {
    ready: () => invoke('app:ready'),
    openExternal: (url) => invoke('app:open-external', url),
    copy: (text) => invoke('app:copy', text)
  },
  settings: {
    get: () => invoke('settings:get'),
    update: (patch) => invoke('settings:update', patch)
  },
  wallet: {
    state: () => invoke('wallet:state'),
    unlock: (password) => invoke('wallet:unlock', { password }),
    create: (password) => invoke('wallet:create', { password }),
    import: (mnemonic, password) => invoke('wallet:import', { mnemonic, password }),
    exportMnemonic: () => invoke('wallet:export'),
    lock: () => invoke('wallet:lock'),
    delete: () => invoke('wallet:delete'),
    refreshBalance: () => invoke('wallet:balance'),
    history: (params) => invoke('wallet:history', params),
    send: (params) => invoke('wallet:send', params)
  },
  market: {
    otc: () => invoke('market:otc'),
    poolStats: (address) => invoke('market:pool-stats', { address }),
    poolRanking: () => invoke('market:pool-ranking')
  },
  miner: {
    state: () => invoke('miner:state'),
    startStratum: (settings) => invoke('miner:start-stratum', settings),
    startSolo: (settings) => invoke('miner:start-solo', settings),
    stop: () => invoke('miner:stop'),
    clearLog: () => invoke('miner:clear-log'),
    buildMetal: () => invoke('miner:build-metal'),
    smokeTest: () => invoke('miner:smoke-test'),
    proxyTest: (proxy) => invoke('miner:proxy-test', { proxy }),
    onState: (callback) => {
      const listener = (_event, state) => callback(state);
      ipcRenderer.on('miner:state', listener);
      return () => ipcRenderer.removeListener('miner:state', listener);
    },
    onLog: (callback) => {
      const listener = (_event, line) => callback(line);
      ipcRenderer.on('miner:log', listener);
      return () => ipcRenderer.removeListener('miner:log', listener);
    }
  }
});
