export function formatHashrate(hs) {
  const value = Number(hs || 0);
  if (value >= 1e12) return `${(value / 1e12).toFixed(2)} TH/s`;
  if (value >= 1e9) return `${(value / 1e9).toFixed(2)} GH/s`;
  if (value >= 1e6) return `${(value / 1e6).toFixed(2)} MH/s`;
  if (value >= 1e3) return `${(value / 1e3).toFixed(2)} kH/s`;
  return `${value.toFixed(0)} H/s`;
}

export function formatBTCC(sats) {
  const n = BigInt(sats || 0);
  const sign = n < 0n ? '-' : '';
  const abs = n < 0n ? -n : n;
  const whole = abs / 100_000_000n;
  const frac = (abs % 100_000_000n).toString().padStart(8, '0');
  return `${sign}${whole}.${frac} BTCC`;
}

export function timeString(date = new Date()) {
  return new Intl.DateTimeFormat('zh-CN', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false
  }).format(date);
}

export function explorerTimeText(timeISO) {
  if (!timeISO) return '—';
  return String(timeISO).replace('T', ' ').replace('Z', '').slice(0, 16);
}
