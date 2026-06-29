import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { WalletStore } from '../../electron/lib/wallet-store.js';

const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

test('WalletStore encrypts mnemonic with password and loads it back', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'btcc-store-'));
  const storePath = path.join(dir, 'wallet.enc.json');
  const store = new WalletStore({ storePath });
  await store.saveMnemonic({ mnemonic, address: 'cc1abc', password: 'correct horse battery staple' });
  const raw = fs.readFileSync(storePath, 'utf8');
  assert.doesNotMatch(raw, /abandon abandon/);
  assert.match(raw, /node\.crypto\.scrypt\.aes-256-gcm/);
  const loaded = await store.decryptMnemonic('correct horse battery staple');
  assert.equal(loaded.mnemonic, mnemonic);
  assert.equal(loaded.legacy, false);
});

test('WalletStore rejects wrong passwords', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'btcc-store-'));
  const storePath = path.join(dir, 'wallet.enc.json');
  const store = new WalletStore({ storePath });
  await store.saveMnemonic({ mnemonic, address: 'cc1abc', password: 'correct horse battery staple' });
  await assert.rejects(() => store.decryptMnemonic('wrong password'), /密码错误/);
});

test('WalletStore exposes legacy plaintext wallet for password migration', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'btcc-store-'));
  const storePath = path.join(dir, 'wallet.enc.json');
  const legacyPath = path.join(dir, 'wallet.json');
  fs.writeFileSync(legacyPath, JSON.stringify({ mnemonic }));
  const store = new WalletStore({ storePath, legacyPath });
  assert.equal(store.metadata().needsMigration, true);
  const loaded = await store.decryptMnemonic('migration password');
  assert.equal(loaded.mnemonic, mnemonic);
  assert.equal(loaded.legacy, true);
  await store.saveMnemonic({ mnemonic: loaded.mnemonic, address: 'cc1abc', password: 'migration password', migratedFromLegacy: true });
  store.finishLegacyMigration();
  assert.equal(fs.existsSync(legacyPath), false);
  assert.equal(fs.existsSync(storePath), true);
});
