import { createHash, createHmac, randomBytes } from 'node:crypto';
import { HDKey } from '@scure/bip32';
import {
  entropyToMnemonic,
  mnemonicToSeedSync,
  validateMnemonic
} from '@scure/bip39';
import { wordlist } from '@scure/bip39/wordlists/english';
import { bech32, bech32m, createBase58check } from '@scure/base';
import { getPublicKey, hashes, sign } from '@noble/secp256k1';
import { BIP84_PATH } from '../constants.js';

hashes.sha256 = (msg) => sha256(msg);
hashes.hmacSha256 = (key, ...msgs) => {
  const h = createHmac('sha256', Buffer.from(key));
  for (const msg of msgs) h.update(Buffer.from(msg));
  return Uint8Array.from(h.digest());
};

const SIGHASH_ALL = 1;
const MIN_CHANGE = 546;
const MIN_RELAY_FEE = 546;
const base58check = createBase58check((msg) => sha256(msg));

export function sha256(data) {
  return Uint8Array.from(createHash('sha256').update(Buffer.from(data)).digest());
}

export function sha256d(data) {
  return sha256(sha256(data));
}

export function hash160(data) {
  const ripemd = createHash('ripemd160').update(Buffer.from(sha256(data))).digest();
  return Uint8Array.from(ripemd);
}

function concatBytes(...parts) {
  return Buffer.concat(parts.map((part) => Buffer.from(part)));
}

function uint32LE(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(Number(n) >>> 0, 0);
  return b;
}

function int64LE(n) {
  const b = Buffer.alloc(8);
  b.writeBigInt64LE(BigInt(n), 0);
  return b;
}

function varint(n) {
  const value = Number(n);
  if (value < 0xfd) return Buffer.from([value]);
  if (value <= 0xffff) {
    const b = Buffer.alloc(3);
    b[0] = 0xfd;
    b.writeUInt16LE(value, 1);
    return b;
  }
  if (value <= 0xffffffff) {
    const b = Buffer.alloc(5);
    b[0] = 0xfe;
    b.writeUInt32LE(value, 1);
    return b;
  }
  const b = Buffer.alloc(9);
  b[0] = 0xff;
  b.writeBigUInt64LE(BigInt(value), 1);
  return b;
}

function reverse32(hex) {
  const b = Buffer.from(hex, 'hex');
  if (b.length !== 32) throw new Error('txid must be 32 bytes');
  return Buffer.from(b).reverse();
}

function p2wpkhScript(pubkeyHash) {
  return concatBytes(Buffer.from([0x00, 0x14]), pubkeyHash);
}

function p2trScript(xOnlyPubkey) {
  return concatBytes(Buffer.from([0x51, 0x20]), xOnlyPubkey);
}

function p2pkhScript(pubkeyHash) {
  return concatBytes(Buffer.from([0x76, 0xa9, 0x14]), pubkeyHash, Buffer.from([0x88, 0xac]));
}

function p2shScript(scriptHash) {
  return concatBytes(Buffer.from([0xa9, 0x14]), scriptHash, Buffer.from([0x87]));
}

function opReturnScript(data) {
  if (data.length > 80) throw new Error('memo must be at most 80 bytes');
  if (data.length <= 75) return concatBytes(Buffer.from([0x6a, data.length]), data);
  return concatBytes(Buffer.from([0x6a, 0x4c, data.length]), data);
}

function txOutput(value, scriptPubkey) {
  return concatBytes(int64LE(value), varint(scriptPubkey.length), scriptPubkey);
}

function outpoint(txidHex, vout) {
  return concatBytes(reverse32(txidHex), uint32LE(vout));
}

function estimateVSize(inputCount, outputs) {
  return 10 + inputCount * 68 + outputs.reduce((sum, output) => sum + output.length, 0);
}

function memoOutput(memo) {
  const text = String(memo || '').trim();
  if (!text) return null;
  return txOutput(0, opReturnScript(Buffer.from(text, 'utf8')));
}

function encodeDerInteger(bytes) {
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0) i += 1;
  let value = Buffer.from(bytes.slice(i));
  if (value[0] & 0x80) value = concatBytes(Buffer.from([0x00]), value);
  return concatBytes(Buffer.from([0x02, value.length]), value);
}

function derEncodeCompactSig(sig64) {
  const sig = Buffer.from(sig64);
  if (sig.length !== 64) throw new Error('compact signature must be 64 bytes');
  const r = encodeDerInteger(sig.slice(0, 32));
  const s = encodeDerInteger(sig.slice(32, 64));
  return concatBytes(Buffer.from([0x30, r.length + s.length]), r, s);
}

export function generateMnemonic() {
  return entropyToMnemonic(randomBytes(16), wordlist);
}

export function normalizeMnemonic(mnemonic) {
  return String(mnemonic || '').trim().toLowerCase().split(/\s+/).filter(Boolean).join(' ');
}

export function assertValidMnemonic(mnemonic) {
  const words = normalizeMnemonic(mnemonic);
  if (!validateMnemonic(words, wordlist)) {
    throw new Error('mnemonic checksum invalid');
  }
  return words;
}

export function p2wpkhAddress(pubkey, hrp = 'cc') {
  const prog = hash160(pubkey);
  return bech32.encode(hrp, [0, ...bech32.toWords(prog)]);
}

export function deriveWallet(mnemonic) {
  const words = assertValidMnemonic(mnemonic);
  const seed = mnemonicToSeedSync(words);
  const hd = HDKey.fromMasterSeed(seed).derive(BIP84_PATH);
  const privateKey = Buffer.from(hd.privKeyBytes);
  const publicKey = Buffer.from(hd.pubKey);
  return {
    mnemonic: words,
    path: BIP84_PATH,
    privateKey,
    publicKey,
    address: p2wpkhAddress(publicKey, 'cc')
  };
}

export function createWallet() {
  return deriveWallet(generateMnemonic());
}

export function addressToScriptPubkey(address) {
  const addr = String(address || '').trim();
  const lower = addr.toLowerCase();
  if (lower.startsWith('cc1')) {
    let decoded;
    try {
      decoded = bech32.decode(addr);
    } catch (bech32Error) {
      try {
        decoded = bech32m.decode(addr);
      } catch {
        throw bech32Error;
      }
    }
    if (decoded.prefix !== 'cc') throw new Error('unsupported witness address hrp');
    const witver = decoded.words[0];
    const prog = Buffer.from(bech32.fromWords(decoded.words.slice(1)));
    if (witver === 0 && prog.length === 20) return p2wpkhScript(prog);
    if (witver === 1 && prog.length === 32) return p2trScript(prog);
    throw new Error('unsupported witness address type');
  }

  const payload = Buffer.from(base58check.decode(addr));
  if (payload.length !== 21) throw new Error('invalid legacy address length');
  const version = payload[0];
  const h = payload.slice(1);
  if (version === 0x00) return p2pkhScript(h);
  if (version === 0x05) return p2shScript(h);
  throw new Error('unsupported legacy address version');
}

export function normalizeRecipientAddress(address) {
  const addr = String(address || '').trim();
  if (!addr) throw new Error('recipient address is required');
  try {
    addressToScriptPubkey(addr);
  } catch (error) {
    throw new Error(`unsupported recipient address: ${error.message}`);
  }
  return addr.toLowerCase().startsWith('cc1') ? addr.toLowerCase() : addr;
}

function selectUtxos(utxos, amountSats, feeRate, outputs) {
  const ordered = [...utxos].sort((a, b) => Number(b.value) - Number(a.value));
  const selected = [];
  let total = 0;
  for (const u of ordered) {
    selected.push(u);
    total += Number(u.value);
    const fee = Math.max(feeRate * estimateVSize(selected.length, outputs), MIN_RELAY_FEE);
    if (total >= amountSats + fee) return selected;
  }
  throw new Error('insufficient funds');
}

function bip143Preimage({
  version,
  hashPrevouts,
  hashSequence,
  outpointBytes,
  scriptCode,
  value,
  sequence,
  hashOutputs,
  locktime,
  sighashType
}) {
  return concatBytes(
    uint32LE(version),
    hashPrevouts,
    hashSequence,
    outpointBytes,
    varint(scriptCode.length),
    scriptCode,
    int64LE(value),
    uint32LE(sequence),
    hashOutputs,
    uint32LE(locktime),
    uint32LE(sighashType)
  );
}

function normalizeUtxo(u) {
  return {
    txid: String(u.tx_hash || u.txid || u.hash || ''),
    vout: Number(u.tx_pos ?? u.vout ?? u.index ?? 0),
    value: Number(u.value ?? u.amount_sats ?? 0)
  };
}

export function buildSignedTx({
  utxos,
  recipient,
  amountSats,
  changeAddress,
  privateKey,
  publicKey,
  feeRateSatVb,
  locktime = 0,
  memo = ''
}) {
  const amount = Number(amountSats);
  if (!Number.isSafeInteger(amount) || amount <= 0) throw new Error('amount must be positive');
  if (!Array.isArray(utxos) || utxos.length === 0) throw new Error('no UTXOs');

  const recipientOutput = txOutput(amount, addressToScriptPubkey(recipient));
  const outputs = [recipientOutput];
  const memoOut = memoOutput(memo);
  if (memoOut) outputs.push(memoOut);

  const normalized = utxos.map(normalizeUtxo);
  const feeRate = Math.max(1, Number(feeRateSatVb || 1));
  const selected = selectUtxos(normalized, amount, feeRate, outputs);

  const pubkeyHash = hash160(publicKey);
  const scriptCode = p2pkhScript(pubkeyHash);
  const inputs = selected.map((u) => ({
    txid: u.txid,
    vout: u.vout,
    value: u.value,
    sequence: 0xfffffffd
  }));
  const totalIn = inputs.reduce((sum, input) => sum + input.value, 0);
  let fee = Math.max(feeRate * estimateVSize(inputs.length, outputs), MIN_RELAY_FEE);
  let change = totalIn - amount - fee;

  if (change >= MIN_CHANGE) {
    const changeScript = addressToScriptPubkey(changeAddress);
    const noChangeLeftover = change;
    const feeWithChange = Math.max(
      feeRate * estimateVSize(inputs.length, [...outputs, txOutput(change, changeScript)]),
      MIN_RELAY_FEE
    );
    const changeWithOutput = totalIn - amount - feeWithChange;
    if (changeWithOutput >= MIN_CHANGE) {
      fee = feeWithChange;
      change = changeWithOutput;
      outputs.push(txOutput(change, changeScript));
    } else {
      change = noChangeLeftover;
    }
  }
  if (change < 0) throw new Error('insufficient funds');

  const version = 2;
  const vin = concatBytes(
    ...inputs.map((input) => concatBytes(outpoint(input.txid, input.vout), Buffer.from([0x00]), uint32LE(input.sequence)))
  );
  const vout = concatBytes(...outputs);
  const hashPrevouts = sha256d(concatBytes(...inputs.map((i) => outpoint(i.txid, i.vout))));
  const hashSequence = sha256d(concatBytes(...inputs.map((i) => uint32LE(i.sequence))));
  const hashOutputs = sha256d(vout);

  const witnesses = inputs.map((input) => {
    const preimage = bip143Preimage({
      version,
      hashPrevouts,
      hashSequence,
      outpointBytes: outpoint(input.txid, input.vout),
      scriptCode,
      value: input.value,
      sequence: input.sequence,
      hashOutputs,
      locktime,
      sighashType: SIGHASH_ALL
    });
    const digest = sha256d(preimage);
    const sig64 = sign(digest, privateKey, { lowS: true });
    const sigDer = derEncodeCompactSig(sig64);
    return [concatBytes(sigDer, Buffer.from([SIGHASH_ALL])), Buffer.from(publicKey)];
  });

  const witnessPart = concatBytes(
    ...witnesses.map((stack) => concatBytes(varint(stack.length), ...stack.map((item) => concatBytes(varint(item.length), item))))
  );

  const body = concatBytes(
    uint32LE(version),
    Buffer.from([0x00, 0x01]),
    varint(inputs.length),
    vin,
    varint(outputs.length),
    vout,
    witnessPart,
    uint32LE(locktime)
  );
  return {
    rawtx: body.toString('hex'),
    fee,
    change,
    selectedUtxos: selected
  };
}

export function publicKeyFromPrivate(privateKey) {
  return Buffer.from(getPublicKey(privateKey, true));
}

export function classifyTxAction(parsed, ourScriptHex, txDetailLookup) {
  const outputs = parsed?.outputs || [];
  const inputs = parsed?.inputs || [];
  const ourOutputValue = outputs
    .filter((out) => out.script === ourScriptHex)
    .reduce((sum, out) => sum + Number(out.value || 0), 0);
  let ourInputValue = 0;
  let unresolvedInputs = 0;
  for (const input of inputs) {
    const prevTxid = input.txid || '';
    if (!prevTxid || prevTxid === '00'.repeat(32)) continue;
    try {
      const prev = txDetailLookup(prevTxid);
      const prevOut = (prev.outputs || [])[Number(input.vout)];
      if (prevOut?.script === ourScriptHex) ourInputValue += Number(prevOut.value || 0);
    } catch {
      unresolvedInputs += 1;
    }
  }
  if (unresolvedInputs > 0 && ourInputValue === 0 && ourOutputValue > 0) return ['未知', 0];
  const net = ourOutputValue - ourInputValue;
  if (ourInputValue > 0 && ourOutputValue > 0 && net === 0) return ['自转账', 0];
  if (ourInputValue > 0) return ['转账', net];
  if (ourOutputValue > 0) return ['收到', ourOutputValue];
  return ['未知', 0];
}
