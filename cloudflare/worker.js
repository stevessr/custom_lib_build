// cloudflare/worker.js — S3 私有桶代理
//
// 让 pacman 无需凭证即可通过 Cloudflare Worker 匿名访问私有 S3 兼容桶
// （AWS S3 / Cloudflare R2 / MinIO / Backblaze B2 …）。
//
// 原理：
//   客户端 (匿名) ──> Worker(持有 S3 凭证，SigV4 签名 GET/HEAD) ──> 私有桶
//
// 请求映射 (path-style):
//   GET https://<worker域名>/<BASE_PATH>/<key>
//     -> GET https://<S3_ENDPOINT>/<S3_BUCKET>/<key>   (SigV4 签名)
// 透传 Range 头（pacman 断点续传依赖 206），GET 200 响应写入 Cloudflare 缓存。
//
// ── 部署 ─────────────────────────────────────────────────────────────
//   npx wrangler deploy cloudflare/worker.js --name s3-pacman-proxy
//   npx wrangler secret put S3_ACCESS_KEY_ID
//   npx wrangler secret put S3_SECRET_ACCESS_KEY
//   npx wrangler secret put S3_ENDPOINT    # 如 https://<accountid>.r2.cloudflarestorage.com
//   npx wrangler secret put S3_BUCKET
//   # 可选变量（非 secret）:
//   npx wrangler secret put S3_REGION      # 默认 us-east-1
//   npx wrangler secret put BASE_PATH      # 客户端 URL 前缀，默认空
//
// ── pacman 配置 ──────────────────────────────────────────────────────
//   [arch_lib]
//   SigLevel = Optional TrustAll
//   Server = https://<worker域名>/<BASE_PATH>
//   # 之后：sudo pacman -Sy && sudo pacman -S <包名>
// ─────────────────────────────────────────────────────────────────────

const EMPTY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

// SigV4 响应头白名单（透传给客户端）
const RESPONSE_HEADERS = [
  'content-type',
  'content-length',
  'content-range',
  'accept-ranges',
  'etag',
  'last-modified',
  'cache-control',
  'expires',
  'x-amz-request-id',
  'x-amz-version-id',
];

export default {
  async fetch(request, env, ctx) {
    const method = request.method;
    if (method !== 'GET' && method !== 'HEAD') {
      return new Response('Method Not Allowed', { status: 405 });
    }

    const endpoint = (env.S3_ENDPOINT || '').replace(/\/+$/, '');
    const bucket = env.S3_BUCKET || '';
    const accessKey = env.S3_ACCESS_KEY_ID || '';
    const secretKey = env.S3_SECRET_ACCESS_KEY || '';
    if (!endpoint || !bucket || !accessKey || !secretKey) {
      return new Response('S3 proxy not configured (missing env)', { status: 500 });
    }

    // 剥离 BASE_PATH 前缀得到桶内 key
    const url = new URL(request.url);
    let key = url.pathname;
    const basePath = (env.BASE_PATH || '').replace(/^\/+|\/+$/g, '');
    if (basePath) {
      const prefix = '/' + basePath + '/';
      if (!key.startsWith(prefix)) {
        return new Response('Not Found', { status: 404 });
      }
      key = key.slice(prefix.length);
    }
    key = key.replace(/^\/+/, '');
    if (!key) {
      return new Response('Not Found', { status: 404 });
    }

    // 组装目标 URL（path-style: endpoint/bucket/key）
    const target = new URL(endpoint);
    target.pathname = '/' + bucket + '/' + encodeKey(key);

    // 构造签名头
    const amzDate = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
    const headers = new Headers();
    headers.set('x-amz-content-sha256', EMPTY_SHA256);
    headers.set('x-amz-date', amzDate);
    const range = request.headers.get('range');
    if (range) headers.set('range', range);

    const signed = await signV4({
      method,
      host: target.host,
      path: target.pathname,
      headers: Object.fromEntries(headers.entries()),
      accessKey,
      secretKey,
      region: env.S3_REGION || 'us-east-1',
      service: 's3',
      amzDate,
    });
    headers.set('Authorization', signed.authorization);

    // GET 200 且无 Range 的响应进 Cloudflare 缓存（Cache API 单对象上限
    // 约 512 MiB，更大包缓存写入失败会静默跳过，不影响正确性）
    const cache = caches.default;
    if (method === 'GET' && !range) {
      const cached = await cache.match(request);
      if (cached) return cached;
    }

    const upstream = await fetch(target.toString(), {
      method,
      headers,
      redirect: 'manual',
    });

    const respHeaders = new Headers();
    for (const name of RESPONSE_HEADERS) {
      const value = upstream.headers.get(name);
      if (value) respHeaders.set(name, value);
    }

    const response = new Response(upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: respHeaders,
    });

    if (method === 'GET' && !range && upstream.status === 200) {
      ctx.waitUntil(cache.put(request, response.clone()));
    }
    return response;
  },
};

// ── AWS Signature V4（无依赖实现，可用 node 单测）────────────────────
// headers: { 小写头名：值 }，canonical 排序与 signed-headers 自动生成。
export async function signV4({
  method,
  host,
  path,
  headers = {},
  accessKey,
  secretKey,
  region,
  service,
  amzDate,
}) {
  const datestamp = amzDate.slice(0, 8);
  const signedHeaders = Object.keys(headers).sort().join(';');
  const canonicalHeaders = Object.keys(headers)
    .sort()
    .map((name) => `${name}:${String(headers[name]).trim().replace(/\s+/g, ' ')}\n`)
    .join('');

  const canonicalRequest = [
    method,
    path,
    '', // canonical query（代理不支持 query）
    canonicalHeaders,
    signedHeaders,
    EMPTY_SHA256,
  ].join('\n');

  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    `${datestamp}/${region}/${service}/aws4_request`,
    await sha256Hex(canonicalRequest),
  ].join('\n');

  const signingKey = await hmacChain(secretKey, [datestamp, region, service, 'aws4_request']);
  const signature = bytesToHex(await hmac(signingKey, stringToSign));

  return {
    authorization:
      `AWS4-HMAC-SHA256 Credential=${accessKey}/${datestamp}/${region}/${service}/aws4_request, ` +
      `SignedHeaders=${signedHeaders}, Signature=${signature}`,
    amzDate,
  };
}

// 逐段编码 key（保留 '/' 分隔）
function encodeKey(key) {
  return key
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
}

async function sha256Hex(data) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(data));
  return bytesToHex(new Uint8Array(digest));
}

async function hmac(key, data) {
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    key,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return new Uint8Array(await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(data)));
}

async function hmacChain(secretKey, steps) {
  let key = new TextEncoder().encode('AWS4' + secretKey);
  for (const step of steps) {
    key = await hmac(key, step);
  }
  return key;
}

function bytesToHex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}
