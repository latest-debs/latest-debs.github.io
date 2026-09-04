// test-fetch-record.mjs - self-check for status.html's fetchRecord().
//
// The operating record's whole point is surviving the loss of one host, so
// the multi-origin fallback is the one piece of this page that must not be
// wrong. Runs the real function (extracted from status.html, never a copy)
// against a stubbed fetch. No network.
//
//   node site/test-fetch-record.mjs   ->  "fetch-record: OK"

import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const html = readFileSync(new URL('./status.html', import.meta.url), 'utf8');

// Pull the live source of both the origin list and the function, so this
// test breaks if either is changed rather than silently testing a stale copy.
const origins = html.match(/const RECORD_ORIGINS = \[[\s\S]*?\];/);
const fn = html.match(/function fetchRecord\(path, notFoundValue\) \{[\s\S]*?\n  \}/);
assert.ok(origins, 'RECORD_ORIGINS not found in status.html');
assert.ok(fn, 'fetchRecord() not found in status.html');

const { RECORD_ORIGINS, fetchRecord } = new Function(
  `${origins[0]}\n${fn[0]}\nreturn { RECORD_ORIGINS, fetchRecord };`
)();

assert.ok(RECORD_ORIGINS.length >= 2, 'a single origin defeats the purpose');

// Stub fetch: `plan` maps origin prefix -> {status, body} or 'network-error'.
let calls;
function stub(plan) {
  calls = [];
  globalThis.fetch = (url) => {
    calls.push(url);
    const key = RECORD_ORIGINS.find((o) => url.startsWith(o));
    const r = plan[key];
    if (r === 'network-error') return Promise.reject(new Error('offline'));
    return Promise.resolve({
      status: r.status,
      ok: r.status >= 200 && r.status < 300,
      json: () => Promise.resolve(r.body),
    });
  };
}
const [A, B] = RECORD_ORIGINS;

// 1. First origin answers -> used, second never contacted.
stub({ [A]: { status: 200, body: { ok: 'a' } }, [B]: { status: 200, body: { ok: 'b' } } });
assert.deepEqual(await fetchRecord('dists/parity.json'), { ok: 'a' });
assert.equal(calls.length, 1, 'second origin should not be contacted on success');
assert.equal(calls[0], `${A}/dists/parity.json`);

// 2. First origin down -> falls through to the second. This is the point.
stub({ [A]: 'network-error', [B]: { status: 200, body: { ok: 'b' } } });
assert.deepEqual(await fetchRecord('dists/parity.json'), { ok: 'b' });
assert.equal(calls.length, 2);

// 3. A 404 on the first origin must NOT short-circuit the second.
stub({ [A]: { status: 404 }, [B]: { status: 200, body: { graduated: [1] } } });
assert.deepEqual(await fetchRecord('graduated.json', { graduated: [] }), { graduated: [1] });
assert.equal(calls.length, 2, 'a 404 from one origin must still try the rest');

// 4. 404 everywhere + a default -> the default, not an error.
stub({ [A]: { status: 404 }, [B]: { status: 404 } });
assert.deepEqual(await fetchRecord('graduated.json', { graduated: [] }), { graduated: [] });

// 5. 404 everywhere with no default -> rejects (a missing report is not "fine").
stub({ [A]: { status: 404 }, [B]: { status: 404 } });
await assert.rejects(() => fetchRecord('dists/staleness.json'));

// 6. Every origin down -> rejects, so the page shows its error state.
stub({ [A]: 'network-error', [B]: 'network-error' });
await assert.rejects(() => fetchRecord('dists/staleness.json'));

console.log('fetch-record: OK');
