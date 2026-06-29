import { SATS_PER_BTCC } from '../constants.js';

export function amountToSats(text) {
  const cleaned = String(text || '').trim().replace(',', '.');
  if (!/^\d+(?:\.\d+)?$/.test(cleaned)) {
    throw new Error('amount format invalid');
  }
  const [whole, frac = ''] = cleaned.split('.');
  if (frac.length > 8) {
    throw new Error('amount supports at most 8 decimal places');
  }
  const wholeSats = BigInt(whole) * SATS_PER_BTCC;
  const fracSats = BigInt(frac.padEnd(8, '0'));
  const sats = wholeSats + fracSats;
  if (sats <= 0n) {
    throw new Error('amount must be positive');
  }
  if (sats > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error('amount too large');
  }
  return Number(sats);
}

export function isValidMemo(memo) {
  const text = String(memo || '').trim();
  return Buffer.byteLength(text, 'utf8') <= 80;
}
