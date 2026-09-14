// =====================================================================
//  Supabase Edge Function: line-webhook
//  รับ webhook จาก LINE OA "แจ้งเตือนทำประกันภัย" → ผูก LINE ของเจ้าหน้าที่ด้วยรหัส 6 หลัก
//
//  ตั้งค่าใน Supabase Dashboard → Edge Functions:
//  - ชื่อฟังก์ชัน: line-webhook
//  - ⚠️ ปิด "Verify JWT" (LINE ไม่ได้ส่ง JWT มา — ด่านจริงคือลายเซ็น x-line-signature)
//  - Secrets: LINE_CHANNEL_SECRET (Channel secret) · LINE_CHANNEL_TOKEN (Channel access token)
//    SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY มีให้อัตโนมัติ
//  - LINE Developers → Messaging API → Webhook URL:
//      https://<project-ref>.supabase.co/functions/v1/line-webhook   แล้วเปิด Use webhook
//
//  🔒 ไม่เชื่อ body จนกว่าลายเซ็น HMAC-SHA256 (ด้วย Channel secret) จะตรง → ไม่ตรง = 403
//  🔒 service role ใช้เรียก rpc ins_line_bind_srv ตัวเดียว (ฟังก์ชันนั้น grant ให้ service_role เท่านั้น)
// =====================================================================

const env = (k: string) => (globalThis as any).Deno?.env.get(k) ?? '';
const enc = new TextEncoder();

async function validSignature(raw: string, sig: string | null): Promise<boolean> {
  const secret = env('LINE_CHANNEL_SECRET');
  if (!secret || !sig) return false;
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(raw)));
  let bin = '';
  for (const b of mac) bin += String.fromCharCode(b);
  const expected = btoa(bin);
  if (expected.length !== sig.length) return false;
  let diff = 0;                                   // เทียบแบบเวลาคงที่
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0;
}

async function reply(replyToken: string | undefined, text: string) {
  const token = env('LINE_CHANNEL_TOKEN');
  if (!replyToken || !token) return;
  try {
    const r = await fetch('https://api.line.me/v2/bot/message/reply', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
      body: JSON.stringify({ replyToken, messages: [{ type: 'text', text }] }),
    });
    if (!r.ok) console.warn('LINE reply', r.status, (await r.text()).slice(0, 200));
  } catch (e) { console.warn('LINE reply failed', String(e)); }
}

async function bind(code: string, lineUserId: string): Promise<{ ok: boolean; name?: string; reason?: string }> {
  const url = env('SUPABASE_URL').replace(/\/+$/, '') + '/rest/v1/rpc/ins_line_bind_srv';
  const key = env('SUPABASE_SERVICE_ROLE_KEY');
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: key, Authorization: 'Bearer ' + key },
    body: JSON.stringify({ p_code: code, p_line_user_id: lineUserId }),
  });
  if (!r.ok) throw new Error('rpc ' + r.status + ' ' + (await r.text()).slice(0, 200));
  return await r.json();
}

const HOWTO =
  'วิธีเปิดแจ้งเตือนลูกค้าใหม่:\n' +
  '1) เข้าหลังบ้านฟอร์มขอทำประกัน แล้วล็อกอิน\n' +
  '2) กดปุ่ม "🔗 แจ้งเตือน LINE"\n' +
  '3) พิมพ์รหัส 6 หลักที่ได้ ส่งมาในแชทนี้';

async function handleEvent(ev: any) {
  const userId = ev?.source?.userId;
  if (!userId) return;
  if (ev.type === 'follow') return reply(ev.replyToken, 'ยินดีต้อนรับสู่แจ้งเตือนทำประกันภัย 🛡️\n\n' + HOWTO);
  if (ev.type !== 'message' || ev.message?.type !== 'text') return;

  const m = String(ev.message.text || '').trim().match(/(?:^|\D)(\d{6})(?:\D|$)/);
  if (!m) return reply(ev.replyToken, 'กรุณาพิมพ์ "รหัส 6 หลัก" ที่ได้จากหน้าหลังบ้าน\n\n' + HOWTO);
  try {
    const res = await bind(m[1], userId);
    if (res.ok) {
      return reply(ev.replyToken,
        '✅ ผูกบัญชีเรียบร้อย' + (res.name ? ' — ' + res.name : '') +
        '\n\nต่อจากนี้เมื่อมีคำขอทำประกันที่คุณดูแล ระบบจะแจ้งเตือนมาที่ LINE นี้ทันที');
    }
    return reply(ev.replyToken, '❌ รหัสไม่ถูกต้องหรือหมดอายุแล้ว\nกรุณากดขอรหัสใหม่จากหน้าหลังบ้าน');
  } catch (e) {
    console.error('bind failed', String(e));
    return reply(ev.replyToken, '⚠️ ระบบขัดข้องชั่วคราว กรุณาส่งรหัสอีกครั้งในอีกสักครู่');
  }
}

export async function handler(req: Request): Promise<Response> {
  if (req.method !== 'POST') return new Response('ok', { status: 200 });
  const raw = await req.text();
  if (!(await validSignature(raw, req.headers.get('x-line-signature')))) {
    return new Response('forbidden', { status: 403 });
  }
  let body: any = {};
  try { body = JSON.parse(raw || '{}'); } catch { return new Response('bad json', { status: 400 }); }
  // ปุ่ม Verify ของ LINE ส่ง events ว่างมา → ตอบ 200 ได้เลย
  await Promise.all((body.events || []).map((ev: any) => handleEvent(ev).catch((e) => console.error(String(e)))));
  return new Response('ok', { status: 200 });
}

(globalThis as any).Deno?.serve(handler);
