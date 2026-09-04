// latest-debs CI status proxy.
//
// GET /ci-status -> { generated_at, repos: [...] } — same shape as the
// static ci-status.json the dashboard falls back to.
//
// Freshness: KV cache with stale-while-revalidate. Fresh cache is served
// as-is; stale cache is served immediately (stale:true) while a background
// refresh runs via waitUntil.
//
// Subrequest budget: the free plan caps a single invocation at 50
// subrequests, and a full refresh needs 1 (org repo list) + N (per-repo
// latest run) calls. The repo list is split into batches and each batch is
// fetched through a self-service binding — every bound invocation gets its
// own 50-call budget. /_batch is internal-only (shared key header).

const ORG = 'latest-debs';
const FRESH_MS = 15 * 60 * 1000; // 15 min
const KV_KEY = 'ci-status:v6'; // bump on deploy to bypass stale KV edge caches
const ALLOWED_ORIGINS = ['https://latest-debs.github.io'];
const BATCH_SIZE = 40; // < 50-call invocation cap
const RUN_CONCURRENCY = 8;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === '/_batch') {
      return handleBatch(request, env);
    }

    const corsOrigin = request.headers.get('Origin');
    const allowCors = corsOrigin !== null && ALLOWED_ORIGINS.includes(corsOrigin);

    const headers = {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
    };
    if (allowCors) {
      headers['Access-Control-Allow-Origin'] = corsOrigin;
      headers['Vary'] = 'Origin';
    }
    const noStoreHeaders = { ...headers, 'Cache-Control': 'no-store' };

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers });
    }
    if (url.pathname !== '/ci-status' || request.method !== 'GET') {
      return new Response(JSON.stringify({ error: 'not found' }), { status: 404, headers });
    }

    let cached = null;
    try {
      cached = await env.CI_STATUS.get(KV_KEY, 'json');
    } catch (err) {
      console.error('kv read failed', err);
    }

    if (cached && Date.now() - cached.cached_at < FRESH_MS) {
      return new Response(JSON.stringify(cached.data), { headers });
    }

    // Stale (or missing) cache: refresh in the background, serve what we have.
    if (cached) {
      ctx.waitUntil(refreshAndCache(env));
      return new Response(JSON.stringify({ ...cached.data, stale: true }), {
        headers: noStoreHeaders,
      });
    }

    // Cold start: nothing to serve, must block until the refresh lands.
    try {
      const data = await buildStatus(env);
      ctx.waitUntil(
        env.CI_STATUS.put(KV_KEY, JSON.stringify({ cached_at: Date.now(), data })),
      );
      return new Response(JSON.stringify(data), { headers });
    } catch (err) {
      console.error('cold refresh failed', err);
      return new Response(JSON.stringify({ error: 'upstream unavailable' }), {
        status: 502,
        headers: noStoreHeaders,
      });
    }
  },
};

async function refreshAndCache(env) {
  try {
    const data = await buildStatus(env);
    await env.CI_STATUS.put(KV_KEY, JSON.stringify({ cached_at: Date.now(), data }));
  } catch (err) {
    console.error('background refresh failed', err); // stale cache stays as-is
  }
}

// --- refresh ----------------------------------------------------------------

async function gh(path, env) {
  const res = await fetch(`https://api.github.com${path}`, {
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN.trim()}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'latest-debs-ci-status-worker',
    },
  });
  if (!res.ok) {
    throw new Error(`github ${res.status} for ${path}`);
  }
  return res.json();
}

async function buildStatus(env) {
  // Repo inventory (non-archived), paginated. Usually a single page.
  const repos = [];
  for (let page = 1; page <= 3; page++) {
    const batch = await gh(`/orgs/${ORG}/repos?per_page=100&page=${page}`, env);
    repos.push(...batch);
    if (batch.length < 100) break;
  }
  const active = repos
    .filter((r) => !r.archived)
    .map((r) => ({ name: r.name, url: r.html_url }))
    .sort((a, b) => a.name.localeCompare(b.name));

  // Split into batches; each goes through a service-binding invocation with
  // its own subrequest budget. No per-call retries: a missed repo simply
  // waits for the next refresh cycle instead of eating the 50-call cap.
  const batches = [];
  for (let i = 0; i < active.length; i += BATCH_SIZE) {
    batches.push(active.slice(i, i + BATCH_SIZE));
  }
  const results = await Promise.all(batches.map((batch) => fetchBatch(batch, env)));
  const entries = results.flat().sort((a, b) => a.name.localeCompare(b.name));

  return { generated_at: new Date().toISOString(), repos: entries };
}

async function fetchBatch(batch, env) {
  const res = await env.SELF.fetch('https://internal/_batch', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Internal-Key': env.INTERNAL_KEY,
    },
    body: JSON.stringify({ repos: batch }),
  });
  if (!res.ok) {
    throw new Error(`batch fetch failed: ${res.status}`);
  }
  return res.json();
}

// --- batch handler (internal) -----------------------------------------------

async function handleBatch(request, env) {
  if (request.method !== 'POST' || request.headers.get('X-Internal-Key') !== env.INTERNAL_KEY) {
    return new Response(JSON.stringify({ error: 'forbidden' }), { status: 403 });
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({ error: 'bad request' }), { status: 400 });
  }

  const entries = await Promise.all(
    (body.repos || []).slice(0, BATCH_SIZE).map(async (repo) => {
      const base = {
        name: repo.name,
        url: repo.url,
        workflow: null,
        conclusion: null,
        status: null,
        branch: null,
        run_url: null,
        created_at: null,
      };
      try {
        const data = await gh(
          `/repos/${ORG}/${repo.name}/actions/runs?per_page=1`,
          env,
        );
        const run = data.workflow_runs?.[0];
        if (!run) return base;
        return {
          ...base,
          workflow: run.name ?? null,
          conclusion: run.conclusion ?? null,
          status: run.status ?? null,
          branch: run.head_branch ?? null,
          run_url: run.html_url ?? null,
          created_at: run.created_at ?? null,
        };
      } catch (err) {
        console.error(`run fetch failed for ${repo.name}`, err);
        return base; // surfaced as "no runs"; next cycle fixes it
      }
    }),
  );
  return new Response(JSON.stringify(entries), {
    headers: { 'Content-Type': 'application/json' },
  });
}
