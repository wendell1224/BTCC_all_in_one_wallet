import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { SettingsStore } from '../../electron/lib/settings-store.js';

test('SettingsStore preserves low-power mining types and clamps duty percent', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'btcc-settings-'));
  const store = new SettingsStore(path.join(dir, 'settings.json'));
  const saved = store.update({
    lowPowerMining: true,
    miningDutyPercent: 2,
    address: 'cc1qexample'
  });
  assert.equal(saved.lowPowerMining, true);
  assert.equal(saved.miningDutyPercent, 5);
  assert.equal(saved.address, 'cc1qexample');

  const loaded = store.getAll();
  assert.equal(typeof loaded.lowPowerMining, 'boolean');
  assert.equal(typeof loaded.miningDutyPercent, 'number');
  assert.equal(loaded.lowPowerMining, true);
  assert.equal(loaded.miningDutyPercent, 5);
});
