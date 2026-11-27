// WebRTC signaling for online play. Stores only the SDP (offer/answer) for a
// room, for 10 minutes. No game data passes through here.
const TTL = 600;
const okCode = (c) => /^[A-Z0-9]{6}$/.test(c);
const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

export async function onRequestGet({ params, request, env }) {
  const code = String(params.code).toUpperCase();
  if (!okCode(code)) return json({ error: 'invalid code' }, 400);
  const want = new URL(request.url).searchParams.get('want');
  if (want !== 'offer' && want !== 'answer') return json({ error: 'want=offer|answer' }, 400);
  const v = await env.TG_ROOMS.get(`${code}:${want}`);
  return v ? json({ sdp: JSON.parse(v) }) : json({ pending: true }, 404);
}

export async function onRequestPost({ params, request, env }) {
  const code = String(params.code).toUpperCase();
  if (!okCode(code)) return json({ error: 'invalid code' }, 400);
  const body = await request.json().catch(() => null);
  if (!body || (body.kind !== 'offer' && body.kind !== 'answer') || typeof body.sdp?.sdp !== 'string' || body.sdp.sdp.length > 20000)
    return json({ error: 'invalid body' }, 400);
  if (body.kind === 'offer' && (await env.TG_ROOMS.get(`${code}:offer`))) return json({ error: 'room already exists' }, 409);
  await env.TG_ROOMS.put(`${code}:${body.kind}`, JSON.stringify(body.sdp), { expirationTtl: TTL });
  return json({ ok: true });
}
