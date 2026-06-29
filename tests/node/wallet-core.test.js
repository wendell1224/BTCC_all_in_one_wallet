import assert from 'node:assert/strict';
import test from 'node:test';
import {
  addressToScriptPubkey,
  buildSignedTx,
  classifyTxAction,
  deriveWallet,
  normalizeRecipientAddress
} from '../../electron/lib/wallet-core.js';
import { amountToSats } from '../../electron/lib/amount.js';

const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

test('amountToSats is exact and rejects lossy values', () => {
  assert.equal(amountToSats('0.00000001'), 1);
  assert.equal(amountToSats('1,23456789'), 123_456_789);
  assert.throws(() => amountToSats('0.000000001'), /8 decimal/);
  assert.throws(() => amountToSats('0'), /positive/);
  assert.throws(() => amountToSats('nan'), /format/);
});

test('deriveWallet creates expected cc1 address for known mnemonic', () => {
  const wallet = deriveWallet(mnemonic);
  assert.equal(wallet.address, 'cc1qcr8te4kr609gcawutmrza0j4xv80jy8zrw2myk');
  assert.equal(wallet.privateKey.length, 32);
  assert.equal(wallet.publicKey.length, 33);
});

test('addressToScriptPubkey supports witness and legacy recipients', () => {
  assert.equal(addressToScriptPubkey('cc1qul8xq8urtf8rgg4px6xvdz4hf5fufks7grjwvx').subarray(0, 2).toString('hex'), '0014');
  assert.equal(addressToScriptPubkey('1BoatSLRHtKNngkdXEeobR76b53LETtpyT').subarray(0, 3).toString('hex'), '76a914');
  assert.equal(normalizeRecipientAddress('1BoatSLRHtKNngkdXEeobR76b53LETtpyT'), '1BoatSLRHtKNngkdXEeobR76b53LETtpyT');
  assert.throws(() => normalizeRecipientAddress('cc1qul8xq8urtf8rgg4px6xvdz4hf5fufks7grjwvy'), /unsupported recipient/);
});

test('signed segwit tx has empty scriptSig and memo OP_RETURN', () => {
  const wallet = deriveWallet(mnemonic);
  const tx = buildSignedTx({
    utxos: [{ tx_hash: 'ab'.repeat(32), tx_pos: 0, value: 100_000_000 }],
    recipient: wallet.address,
    amountSats: 50_000_000,
    changeAddress: wallet.address,
    privateKey: wallet.privateKey,
    publicKey: wallet.publicKey,
    feeRateSatVb: 10,
    memo: 'hello'
  });
  const raw = Buffer.from(tx.rawtx, 'hex');
  const scriptSigLenIndex = 4 + 2 + 1 + 36;
  assert.equal(raw[scriptSigLenIndex], 0);
  assert.match(tx.rawtx, /6a0568656c6c6f/);
  assert.equal(tx.fee, 1560);
});

test('memo rejects over 80 bytes', () => {
  const wallet = deriveWallet(mnemonic);
  assert.throws(() => buildSignedTx({
    utxos: [{ tx_hash: 'ab'.repeat(32), tx_pos: 0, value: 100_000_000 }],
    recipient: wallet.address,
    amountSats: 50_000_000,
    changeAddress: wallet.address,
    privateKey: wallet.privateKey,
    publicKey: wallet.publicKey,
    feeRateSatVb: 10,
    memo: 'x'.repeat(81)
  }), /80 bytes/);
});

test('classifyTxAction matches receive send unknown and self transfer cases', () => {
  assert.deepEqual(
    classifyTxAction(
      { inputs: [{ txid: '00'.repeat(32), vout: 0 }], outputs: [{ value: 12_345, script: '0014aa' }] },
      '0014aa',
      () => ({ outputs: [] })
    ),
    ['收到', 12_345]
  );
  const prevTxid = '11'.repeat(32);
  assert.deepEqual(
    classifyTxAction(
      {
        inputs: [{ txid: prevTxid, vout: 0 }],
        outputs: [{ value: 30_000, script: '0014bb' }, { value: 69_000, script: '0014aa' }]
      },
      '0014aa',
      () => ({ outputs: [{ value: 100_000, script: '0014aa' }] })
    ),
    ['转账', -31_000]
  );
  assert.deepEqual(
    classifyTxAction(
      { inputs: [{ txid: '22'.repeat(32), vout: 0 }], outputs: [{ value: 50_000, script: '0014aa' }] },
      '0014aa',
      () => { throw new Error('offline'); }
    ),
    ['未知', 0]
  );
  assert.deepEqual(
    classifyTxAction(
      { inputs: [{ txid: '33'.repeat(32), vout: 0 }], outputs: [{ value: 100_000, script: '0014aa' }] },
      '0014aa',
      () => ({ outputs: [{ value: 100_000, script: '0014aa' }] })
    ),
    ['自转账', 0]
  );
});
