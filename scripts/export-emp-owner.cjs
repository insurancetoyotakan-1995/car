/* สร้างไฟล์ SQL "พนักงานที่เคยทำประกันแล้ว → เจ้าหน้าที่ผู้ดูแลคนเดิม"
 *
 * ที่มา: ไฟล์ Excel รายการกรมธรรม์ (ส่งออกจากระบบฝ่ายประกัน) มีคอลัมน์ ชื่อ / นามสกุล / พนักงานขาย / วันที่แจ้ง
 *   1) จับคู่ "ชื่อ+นามสกุลลูกค้า" กับทำเนียบพนักงาน (ตรงทั้งชื่อ หลังตัดช่องว่างและวงเล็บหมายเหตุ)
 *   2) คนเดียวมีหลายกรมธรรม์ → ใช้ "ผู้ขายของกรมธรรม์ล่าสุด" (เรียงตามวันที่แจ้ง)
 *      ผู้ขายล่าสุดไม่ได้เป็นเจ้าหน้าที่ในระบบแล้ว → ถอยไปหาผู้ขายคนก่อนหน้าที่ยังอยู่
 *   3) "พนักงานขาย" ในไฟล์เป็นชื่อต้น → เทียบชื่อต้นของเจ้าหน้าที่ประกันในทำเนียบ (ต้องไม่ซ้ำกัน)
 *
 * วิธีใช้ (อ่านอย่างเดียว ไม่แก้ฐานข้อมูลในออฟฟิศ):
 *   node scripts/export-emp-owner.cjs "C:\Users\...\พนง.บริษัท.xlsx"
 *
 * ผลลัพธ์: supabase/ins-emp-owner.sql (อยู่ใน .gitignore) → วางใน SQL Editor แล้ว Run · รันซ้ำได้
 */
const fs = require('fs');
const path = require('path');
const BACKEND = 'C:/Users/dmk-006/.claude/backups/backend';
const XLSX = require(BACKEND + '/public/xlsx.full.min.js');
const Database = require(BACKEND + '/node_modules/better-sqlite3');

const SRC = process.argv[2];
const DB_FILE = process.env.VOUCHER_DB || 'E:/VoucherSystem/data/voucher.db';
const OUT = path.join(__dirname, '..', 'supabase', 'ins-emp-owner.sql');
const REPORT = process.env.REPORT || '';
if (!SRC || !fs.existsSync(SRC)) { console.error('ไม่พบไฟล์ Excel: ' + SRC); process.exit(1); }

const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
// ตัดวงเล็บหมายเหตุ เช่น "สุจิตรา(พนักงาน)" · "สรรพวัฒน์ สงวนทรัพย์(พนักงาน)" แล้วเอาช่องว่างออกทั้งหมด
const key = (s) => norm(s).replace(/[(（][^)）]*[)）]/g, '').replace(/\s/g, '');

const wb = XLSX.read(fs.readFileSync(SRC), { type: 'buffer' });
const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '' });
const H = rows[0].map(norm);
const col = (n) => { const i = H.indexOf(n); if (i < 0) { console.error('ไม่พบคอลัมน์: ' + n); process.exit(1); } return i; };
const C = { fn: col('ชื่อ'), ln: col('นามสกุล'), sale: col('พนักงานขาย'), at: col('วันที่แจ้ง'), no: col('เลขกรมธรรม์') };

const db = new Database(DB_FILE, { readonly: true });
const users = db.prepare('SELECT data FROM users').all()
  .map((r) => { try { return JSON.parse(r.data); } catch (e) { return null; } })
  .filter((u) => u && u.empId && u.name && u.active !== false);
db.close();

const byName = new Map();
for (const u of users) {
  const k = key(u.name);
  byName.set(k, byName.has(k) ? null : u);          // ชื่อซ้ำกันในทำเนียบ = ไม่เดา
}
const agents = users.filter((u) => /ประกัน/.test(String(u.position || '') + ' ' + String(u.dept || '')));
const agentByFirst = new Map();
for (const a of agents) {
  const first = norm(a.name).split(' ')[0];
  agentByFirst.set(first, agentByFirst.has(first) ? null : a);
}

const hist = new Map();                              // empId → [{at, sale, idx}]
let matchedRows = 0;
rows.slice(1).forEach((r, idx) => {
  if (!norm(r[C.fn])) return;
  const u = byName.get(key(r[C.fn] + r[C.ln]));
  if (!u) return;
  matchedRows++;
  const at = typeof r[C.at] === 'number' ? r[C.at] : 0;
  if (!hist.has(u.empId)) hist.set(u.empId, { u, list: [] });
  hist.get(u.empId).list.push({ at, idx, sale: norm(r[C.sale]), no: norm(r[C.no]) });
});

const map = [], skipped = [];
for (const [empId, { u, list }] of hist) {
  list.sort((a, b) => (b.at - a.at) || (b.idx - a.idx));
  const latest = list[0];
  const pick = list.find((x) => agentByFirst.get(x.sale));
  if (!pick) { skipped.push({ empId, name: norm(u.name), sale: latest.sale, n: list.length }); continue; }
  const a = agentByFirst.get(pick.sale);
  map.push({ empId, name: norm(u.name), agent: a.empId, agentName: norm(a.name), policies: list.length,
             lastPolicy: pick.no, fallback: pick !== latest ? latest.sale : '' });
}
map.sort((a, b) => a.empId.localeCompare(b.empId));

const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";
const sql = [
  '-- พนักงานที่เคยทำประกันแล้ว → เจ้าหน้าที่ผู้ดูแลคนเดิม',
  '-- สร้างโดย scripts/export-emp-owner.cjs เมื่อ ' + new Date().toLocaleString('th-TH'),
  '-- ที่มา: ' + path.basename(SRC) + ' · จับคู่ได้ ' + map.length + ' คน · รันซ้ำได้ (ทับของเดิมที่มาจาก Excel)',
  '-- ⚠️ ต้องรัน migrate-2026-09-15-emp-owner.sql ก่อน',
  '',
  /* 🔑 brand = toyota เสมอ: ต้นทางคือทำเนียบพนักงานโตโยต้า (voucher.db)
     กุญแจหลักเป็น (brand, emp_id) ตั้งแต่ migrate-2026-09-21-brand.sql */
  "insert into public.ins_emp_owner (brand, emp_id, agent_emp_id, source, note) values",
  map.map((m) => "  ('toyota', " + [q(m.empId), q(m.agent), q('excel'),
    // 🔒 ไม่ส่งเลขกรมธรรม์ขึ้นคลาวด์ — ไม่จำเป็นต่อการแจกงาน
    q(m.policies + ' กรมธรรม์ใน Excel' + (m.fallback ? ' · ผู้ขายล่าสุด ' + m.fallback + ' ไม่อยู่ในระบบ' : ''))].join(', ') + ')').join(',\n'),
  'on conflict (brand, emp_id) do update',
  '  set agent_emp_id = excluded.agent_emp_id, source = excluded.source, note = excluded.note, updated_at = now();',
  '',
].join('\n');
fs.writeFileSync(OUT, sql, 'utf8');

console.log('แถวใน Excel ที่ชื่อตรงกับพนักงาน: ' + matchedRows);
console.log('พนักงานที่จับคู่ผู้ดูแลได้: ' + map.length + ' คน · ข้าม ' + skipped.length + ' คน');
console.log('เขียนไฟล์: ' + OUT);
if (REPORT) fs.writeFileSync(REPORT, JSON.stringify({ map, skipped,
  agentsInFile: [...new Set(rows.slice(1).map((r) => norm(r[C.sale])))],
  agents: agents.map((a) => a.empId + ' ' + norm(a.name)) }, null, 1), 'utf8');
