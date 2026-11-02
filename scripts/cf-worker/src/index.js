/**
 * Lux Download Worker — Cloudflare Worker
 * 
 * Proxies Google Drive downloads so users never see the virus scan page.
 * The worker authenticates with Google using a service account and streams
 * the file directly to the browser.
 *
 * Routes:
 *   GET /mac       → latest macOS DMG
 *   GET /win       → latest Windows EXE
 *   GET /mac/:rev  → specific macOS revision
 *   GET /win/:rev  → specific Windows revision
 *   GET /versions  → JSON list of revisions for both platforms
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // CORS for the release page
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Expose-Headers': 'Content-Length',
    };

    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders });
    }

    try {
      if (path === '/mac' || path === '/mac/latest') {
        return await streamFile(env, env.MAC_FILE_ID, 'Lux-macOS.dmg', corsHeaders);
      }
      if (path === '/win' || path === '/win/latest') {
        return await streamFile(env, env.WIN_FILE_ID, 'Lux-Windows.exe', corsHeaders);
      }
      // Beta channel — same virus-scan-free proxy as stable, different files.
      // MUST come before the '/mac/:rev' / '/win/:rev' handlers below, or
      // 'beta' would be treated as a revision id.
      if (path === '/mac/beta') {
        return await streamFile(env, env.MAC_BETA_FILE_ID, 'Lux-macOS-beta.dmg', corsHeaders);
      }
      if (path === '/win/beta') {
        return await streamFile(env, env.WIN_BETA_FILE_ID, 'Lux-Windows-beta.exe', corsHeaders);
      }
      if (path.startsWith('/mac/')) {
        const rev = path.substring(5);
        return await streamRevision(env, env.MAC_FILE_ID, rev, 'Lux-macOS.dmg', corsHeaders);
      }
      if (path.startsWith('/win/')) {
        const rev = path.substring(5);
        return await streamRevision(env, env.WIN_FILE_ID, rev, 'Lux-Windows.exe', corsHeaders);
      }
      if (path === '/versions') {
        return await listVersions(env, corsHeaders);
      }

      return new Response(JSON.stringify({
        routes: ['/mac', '/win', '/mac/beta', '/win/beta', '/mac/:rev', '/win/:rev', '/versions']
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    } catch (e) {
      return new Response(JSON.stringify({ error: e.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }
  }
};

async function getAccessToken(env) {
  // Use the service account key stored as a secret
  const key = JSON.parse(env.GOOGLE_SERVICE_ACCOUNT_KEY);
  const now = Math.floor(Date.now() / 1000);
  const header = btoa(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = btoa(JSON.stringify({
    iss: key.client_email,
    scope: 'https://www.googleapis.com/auth/drive.readonly',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));

  const signInput = `${header}.${claim}`;
  const privateKey = await importRSAKey(key.private_key);
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    privateKey,
    new TextEncoder().encode(signInput)
  );
  const jwt = `${signInput}.${base64url(signature)}`;

  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const data = await resp.json();
  return data.access_token;
}

async function streamFile(env, fileId, filename, corsHeaders) {
  const token = await getAccessToken(env);
  const resp = await fetch(
    `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media`,
    { headers: { Authorization: `Bearer ${token}` } }
  );
  if (!resp.ok) {
    return new Response(`Drive API error: ${resp.status}`, { status: 502, headers: corsHeaders });
  }
  return new Response(resp.body, {
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/octet-stream',
      'Content-Disposition': `attachment; filename="${filename}"`,
      'Content-Length': resp.headers.get('Content-Length') || '',
    }
  });
}

async function streamRevision(env, fileId, revisionId, filename, corsHeaders) {
  const token = await getAccessToken(env);
  const resp = await fetch(
    `https://www.googleapis.com/drive/v3/files/${fileId}/revisions/${revisionId}?alt=media`,
    { headers: { Authorization: `Bearer ${token}` } }
  );
  if (!resp.ok) {
    return new Response(`Drive API error: ${resp.status}`, { status: 502, headers: corsHeaders });
  }
  return new Response(resp.body, {
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/octet-stream',
      'Content-Disposition': `attachment; filename="${filename}"`,
      'Content-Length': resp.headers.get('Content-Length') || '',
    }
  });
}

async function listVersions(env, corsHeaders) {
  const token = await getAccessToken(env);
  const [macRevs, winRevs] = await Promise.all([
    fetchRevisions(token, env.MAC_FILE_ID),
    fetchRevisions(token, env.WIN_FILE_ID),
  ]);
  return new Response(JSON.stringify({ mac: macRevs, win: winRevs }, null, 2), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

async function fetchRevisions(token, fileId) {
  const resp = await fetch(
    `https://www.googleapis.com/drive/v3/files/${fileId}/revisions?fields=revisions(id,modifiedTime,size)&pageSize=100`,
    { headers: { Authorization: `Bearer ${token}` } }
  );
  if (!resp.ok) return [];
  const data = await resp.json();
  return (data.revisions || []).reverse().map(r => ({
    id: r.id,
    date: r.modifiedTime,
    sizeMB: Math.round(parseInt(r.size || '0') / 1024 / 1024),
  }));
}

// Crypto helpers for JWT signing
async function importRSAKey(pem) {
  const pemContents = pem.replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\n/g, '');
  const der = Uint8Array.from(atob(pemContents), c => c.charCodeAt(0));
  return crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
}

function base64url(buffer) {
  const bytes = new Uint8Array(buffer);
  let str = '';
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
