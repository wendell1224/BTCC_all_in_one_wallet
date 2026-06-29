import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { WalletService } from '../../electron/lib/wallet-service.js';
import { WalletStore } from '../../electron/lib/wallet-store.js';

test('WalletService refreshes balance after create and on explicit refresh', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'btcc-wallet-service-'));
  const store = new WalletStore({ storePath: path.join(dir, 'wallet.enc.json') });
  let confirmed = 123456789;
  const api = {
    fetchBalance: async (address) => ({
      address,
      confirmed,
      unconfirmed: 42
    })
  };
  const service = new WalletService({ store, api });
  const created = await service.create({ password: 'correct horse battery staple' });
  assert.equal(created.balanceConfirmed, 123456789);
  assert.equal(created.balanceUnconfirmed, 42);

  confirmed = 987654321;
  const refreshed = await service.refreshBalance();
  assert.equal(refreshed.balanceConfirmed, 987654321);
  assert.equal(refreshed.balanceUnconfirmed, 42);

  const state = await service.state({ refreshBalance: true });
  assert.equal(state.balanceConfirmed, 987654321);
});
