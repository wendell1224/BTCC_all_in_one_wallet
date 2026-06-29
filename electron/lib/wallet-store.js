import fs from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import { createCipheriv, createDecipheriv, randomBytes, scrypt as scryptCb } from 'node:crypto';

const scrypt = promisify(scryptCb);
const KDF = Object.freeze({
  name: 'scrypt',
  N: 32768,
  r: 8,
  p: 1,
  keyLength: 32,
  maxmem: 64 * 1024 * 1024
});
const LEGACY_SAFE_STORAGE_ENCRYPTION = ['electron', 'safeStorage'].join('.');

function chmodOwnerOnly(file) {
  try {
    fs.chmodSync(file, 0o600);
  } catch {
    // Best effort. Windows may not support POSIX permissions.
  }
}

function atomicWriteJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, file);
  chmodOwnerOnly(file);
}

function assertUsablePassword(password) {
  const value = String(password || '');
  if (value.length < 8) {
    throw new Error('钱包密码至少 8 位');
  }
  return value;
}

async function deriveKey(password, salt, params = KDF) {
  return scrypt(password, salt, params.keyLength || 32, {
    N: params.N || KDF.N,
    r: params.r || KDF.r,
    p: params.p || KDF.p,
    maxmem: params.maxmem || KDF.maxmem
  });
}

export class WalletStore {
  constructor({ storePath, legacyPath }) {
    this.storePath = storePath;
    this.legacyPath = legacyPath;
  }

  hasEncryptedWallet() {
    return fs.existsSync(this.storePath);
  }

  hasLegacyWallet() {
    return Boolean(this.legacyPath && fs.existsSync(this.legacyPath));
  }

  hasWallet() {
    return this.hasEncryptedWallet() || this.hasLegacyWallet();
  }

  metadata() {
    if (this.hasEncryptedWallet()) {
    const raw = JSON.parse(fs.readFileSync(this.storePath, 'utf8'));
    if (raw.encryption === LEGACY_SAFE_STORAGE_ENCRYPTION) {
      return {
        version: raw.version,
        encryption: raw.encryption,
        address: raw.address || '',
        createdAt: raw.createdAt || '',
        migratedFromLegacy: false,
        needsMigration: false,
        unsupportedSafeStorage: true
      };
    }
    return {
        version: raw.version,
        encryption: raw.encryption,
        address: raw.address || '',
        createdAt: raw.createdAt || '',
        migratedFromLegacy: Boolean(raw.migratedFromLegacy),
        needsMigration: false
      };
    }
    if (this.hasLegacyWallet()) {
      return {
        version: 0,
        encryption: 'legacy-plaintext',
        address: '',
        createdAt: '',
        migratedFromLegacy: false,
        needsMigration: true
      };
    }
    return null;
  }

  async saveMnemonic({ mnemonic, address, password, migratedFromLegacy = false }) {
    const pass = assertUsablePassword(password);
    const salt = randomBytes(16);
    const iv = randomBytes(12);
    const key = await deriveKey(pass, salt, KDF);
    const cipher = createCipheriv('aes-256-gcm', key, iv);
    const ciphertext = Buffer.concat([
      cipher.update(String(mnemonic), 'utf8'),
      cipher.final()
    ]);
    const tag = cipher.getAuthTag();
    atomicWriteJson(this.storePath, {
      version: 2,
      encryption: 'node.crypto.scrypt.aes-256-gcm',
      kdf: KDF,
      address,
      createdAt: new Date().toISOString(),
      migratedFromLegacy,
      salt: salt.toString('base64'),
      iv: iv.toString('base64'),
      tag: tag.toString('base64'),
      encryptedMnemonic: ciphertext.toString('base64')
    });
  }

  async decryptMnemonic(password) {
    const pass = assertUsablePassword(password);
    if (!this.hasEncryptedWallet()) {
      if (this.hasLegacyWallet()) {
        const raw = JSON.parse(fs.readFileSync(this.legacyPath, 'utf8'));
        const mnemonic = String(raw.mnemonic || '').trim();
        if (!mnemonic) throw new Error('旧钱包文件没有助记词');
        return { mnemonic, legacy: true };
      }
      return null;
    }
    const raw = JSON.parse(fs.readFileSync(this.storePath, 'utf8'));
    if (raw.encryption === LEGACY_SAFE_STORAGE_ENCRYPTION) {
      throw new Error('旧版本加密钱包不能在“不访问钥匙串”模式下解密，请使用助记词重新导入并设置钱包密码');
    }
    if (raw.encryption !== 'node.crypto.scrypt.aes-256-gcm') {
      throw new Error('钱包存储格式不支持');
    }
    const salt = Buffer.from(raw.salt, 'base64');
    const iv = Buffer.from(raw.iv, 'base64');
    const tag = Buffer.from(raw.tag, 'base64');
    const ciphertext = Buffer.from(raw.encryptedMnemonic, 'base64');
    try {
      const key = await deriveKey(pass, salt, raw.kdf || KDF);
      const decipher = createDecipheriv('aes-256-gcm', key, iv);
      decipher.setAuthTag(tag);
      const mnemonic = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8').trim();
      return { mnemonic, legacy: false };
    } catch (error) {
      throw new Error('钱包密码错误或钱包文件已损坏');
    }
  }

  finishLegacyMigration() {
    if (this.legacyPath) fs.rmSync(this.legacyPath, { force: true });
  }

  deleteWallet() {
    fs.rmSync(this.storePath, { force: true });
    if (this.legacyPath) fs.rmSync(this.legacyPath, { force: true });
  }
}
