import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildBlockHeader,
  buildJob,
  diffToTarget,
  gpuThrottleSleepMs,
  normalizeGpuDutyPercent,
  parsePoolURL,
  parseProxyUrl,
  stratumPrevhashToLe32,
  submitNonceHex
} from '../../electron/lib/stratum-node.js';
import { buildCoinbaseTx, compactToTarget, merkleRootLe } from '../../electron/lib/solo-node.js';

test('parsePoolURL and parseProxyUrl normalize inputs', () => {
  assert.deepEqual(parsePoolURL('pool.btc-classic.org:63101'), {
    secure: false,
    host: 'pool.btc-classic.org',
    port: 63101
  });
  assert.deepEqual(parseProxyUrl('socks5h://u:p@127.0.0.1:7891'), {
    scheme: 'socks5',
    host: '127.0.0.1',
    port: 7891,
    username: 'u',
    password: 'p'
  });
});

test('low-power mining helpers clamp duty cycle and compute idle time', () => {
  assert.equal(normalizeGpuDutyPercent({ lowPowerMining: false, miningDutyPercent: 5 }), 100);
  assert.equal(normalizeGpuDutyPercent({ lowPowerMining: true, miningDutyPercent: 1 }), 5);
  assert.equal(normalizeGpuDutyPercent({ lowPowerMining: true, miningDutyPercent: 250 }), 100);
  assert.equal(normalizeGpuDutyPercent({ lowPowerMining: 'true', miningDutyPercent: '10' }), 10);
  assert.equal(gpuThrottleSleepMs({ dutyPercent: 100, elapsedMs: 250 }), 0);
  assert.equal(gpuThrottleSleepMs({ dutyPercent: 10, elapsedMs: 250 }), 2250);
  assert.equal(gpuThrottleSleepMs({ dutyPercent: 50, elapsedMs: 250 }), 250);
});

test('stratum helpers preserve protocol byte order', () => {
  assert.equal(stratumPrevhashToLe32('00112233445566778899aabbccddeeff000102030405060708090a0b0c0d0e0f').toString('hex'), '3322110077665544bbaa9988ffeeddcc03020100070605040b0a09080f0e0d0c');
  assert.equal(submitNonceHex(0x1234abcd), '1234abcd');
  assert.equal(diffToTarget(1).toString(16).padStart(64, '0'), '00000000ffff0000000000000000000000000000000000000000000000000000');
});

test('buildJob and buildBlockHeader produce an 80 byte header', () => {
  const job = buildJob([
    '1',
    '00'.repeat(32),
    '01000000',
    'ffffffff',
    [],
    '20000000',
    '1d00ffff',
    '5f5e1000',
    true
  ]);
  const header = buildBlockHeader({ job, coinbase: Buffer.from('01000000ffffffff', 'hex'), nonce: 0, ntimeOverride: 0x5f5e1000 });
  assert.equal(header.length, 80);
});

test('solo coinbase and merkle helpers produce deterministic byte structures', () => {
  assert.equal(compactToTarget(0x1d00ffff).toString(16).padStart(64, '0'), '00000000ffff0000000000000000000000000000000000000000000000000000');
  const payoutScript = Buffer.from('0014' + '11'.repeat(20), 'hex');
  const coinbase = buildCoinbaseTx({
    height: 100,
    coinbaseValue: 50_00000000,
    payoutScript,
    extranonce: Buffer.from('01020304', 'hex'),
    witnessCommitmentScript: null
  });
  assert.equal(coinbase.txidLe.length, 32);
  assert.equal(merkleRootLe([coinbase.txidLe]).toString('hex'), coinbase.txidLe.toString('hex'));
});
