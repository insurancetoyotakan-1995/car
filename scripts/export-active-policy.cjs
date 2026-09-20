/* สร้างไฟล์ SQL "กรมธรรม์ของพนักงานที่ยังไม่หมดอายุ" → ใช้ตัดสินสิทธิ์รถคันที่ 2
 *
 * ที่มา: Excel ของฝ่ายประกัน (คอลัมน์ ชื่อ / นามสกุล / ทะเบียน / เลขตัวถัง / วันหมดอายุ)
 *   1) จับคู่ "ชื่อ+นามสกุล" กับทำเนียบพนักงาน (ตรงทั้งชื่อ หลังตัดช่องว่างและวงเล็บหมายเหตุ · ชื่อซ้ำในทำเนียบ = ไม่เดา)
 *      ถ้าไฟล์มีคอลัมน์ "รหัสพนักงาน" และแถวนั้นกรอกไว้ → ใช้รหัสนั้นเลย (เช่น รถของคู่สมรส/บุตร ที่ชื่อไม่ตรงพนักงาน)
 *      กรอก "ไม่นับ" → ตั้งใจไม่นับรถคันนั้น (เช่น พนักงานเกษียณแล้ว) ไม่ขึ้นเป็นแถวค้าง
 *   2) วันหมดอายุในไฟล์เป็นปี พ.ศ. (9/20/69 = 20 ก.ย. 2569) → เก็บเป็น ค.ศ.
 *   3) ในระบบ: กรมธรรม์ที่ "ยังไม่เลยวันหมดอายุ" = พนักงานใช้สิทธิ์คันแรกไปแล้ว
 *      → รถคันอื่นที่ยื่นเข้ามา = รถคันที่ 2 (ทะเบียน/เลขตัวถังเดียวกัน = ต่ออายุคันเดิม ไม่นับ)
 *      เลยวันหมดอายุแล้ว = ไม่นับ (กลับมาได้สิทธิ์คันแรก)
 *
 * วิธีใช้ (อ่านอย่างเดียว ไม่แก้ฐานข้อมูลในออฟฟิศ):
 *   node scripts/export-active-policy.cjs "Z:\IT\Botbell\งานประกัน\ข้อมูลพนักงานประกันยังไม่หมดอายุ.xlsx"
 *   ใส่ได้หลายไฟล์ (รวมกันเป็นชุดเดียว) เช่น ไฟล์หลัก + ไฟล์ "รอกรอกรหัสพนักงาน" ที่ฝ่ายประกันกรอกรหัสให้แถวที่ชื่อไม่ตรง
 *   → รถคันเดียวกัน (เลขตัวถัง/ทะเบียนเดียวกัน) นับครั้งเดียว · แถวที่ระบุรหัสพนักงานเองชนะแถวที่จับคู่จากชื่อ
 *
 * ผลลัพธ์: supabase/ins-active-policy.sql (อยู่ใน .gitignore) → วางใน SQL Editor แล้ว Run
 *   รันซ้ำ/รันไฟล์ใหม่ได้ — ลบชุดเดิมที่มาจาก Excel แล้วใส่ชุดใหม่แทนทั้งหมด
 * 🔒 ส่งขึ้นคลาวด์แค่ รหัสพนักงาน · ทะเบียน · เลขตัวถัง · วันหมดอายุ (ไม่ส่งชื่อ ที่อยู่ เบอร์โทร)
 */
const fs = require('fs');
const path = require('path');
const BACKEND = 'C:/Users/dmk-006/.claude/backups/backend';
const XLSX = require(BACKEND + '/public/xlsx.full.min.js');
const Database = require(BACKEND + '/node_modules/better-sqlite3');

const SRCS = process.argv.slice(2);
const DB_FILE = process.env.VOUCHER_DB || 'E:/VoucherSystem/data/voucher.db';
const OUT = path.join(__dirname, '..', 'supabase', 'ins-active-policy.sql');
const REPORT = process.env.REPORT || '';
if (!SRCS.length) { console.error('ระบุไฟล์ Excel อย่างน้อย 1 ไฟล์'); process.exit(1); }
for (const f of SRCS) if (!fs.existsSync(f)) { console.error('ไม่พบไฟล์ Excel: ' + f); process.exit(1); }

const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
const key = (s) => norm(s).replace(/[(（][^)）]*[)）]/g, '').replace(/\s/g, '');


/* วันหมดอายุ: ตัวเลขวันที่ของ Excel (ปีเป็น พ.ศ.) หรือข้อความ ด/ว/ปป · ปป = 2 หลักท้ายของ พ.ศ. */
const pad = (n) => String(n).padStart(2, '0');
const vinOf = (v) => norm(v).toUpperCase().replace(/[^0-9A-Z]/g, '').slice(0, 20);
function expDate(v) {
  let y, m, d;
  if (typeof v === 'number') { const p = XLSX.SSF.parse_date_code(v); if (!p) return ''; y = p.y; m = p.m; d = p.d; }
  else {
    const t = /^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/.exec(norm(v));
    if (!t) return '';
    m = +t[1]; d = +t[2]; y = +t[3];
    if (y < 100) y += 2500;
  }
  if (y > 2400) y -= 543;
  if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return '';
  return y + '-' + pad(m) + '-' + pad(d);
}

const db = new Database(DB_FILE, { readonly: true });
const users = db.prepare('SELECT data FROM users').all()
  .map((r) => { try { return JSON.parse(r.data); } catch (e) { return null; } })
  .filter((u) => u && u.empId && u.name && u.active !== false);
db.close();
const byName = new Map();
for (const u of users) { const k = key(u.name); byName.set(k, byName.has(k) ? null : u); }
const byId = new Map(users.map((u) => [String(u.empId), u]));

const out = [], unmatched = [], badDate = [], skipped = [];
let total = 0;
for (const file of SRCS) {
const wb = XLSX.read(fs.readFileSync(file), { type: 'buffer' });
const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '', raw: true });
const H = rows[0].map(norm);
const col = (n) => { const i = H.indexOf(n); if (i < 0) { console.error(path.basename(file) + ' ไม่พบคอลัมน์: ' + n); process.exit(1); } return i; };
const C = { fn: col('ชื่อ'), ln: col('นามสกุล'), plate: col('ทะเบียน'), vin: col('เลขตัวถัง'), exp: col('วันหมดอายุ'),
            emp: H.indexOf('รหัสพนักงาน') };                  // ไม่บังคับ
const src = path.basename(file);
rows.slice(1).forEach((r, i) => {
  const name = norm(r[C.fn] + ' ' + r[C.ln]);
  if (!norm(r[C.fn])) return;
  total++;
  const exp = expDate(r[C.exp]);
  if (!exp) { badDate.push({ src, row: i + 2, name, v: r[C.exp] }); return; }
  if (C.emp >= 0 && norm(r[C.emp]) === 'ไม่นับ') { skipped.push({ src, row: i + 2, name, plate: norm(r[C.plate]), vin: vinOf(r[C.vin]) }); return; }
  const id = C.emp >= 0 ? norm(r[C.emp]).replace(/\D/g, '') : '';
  if (id && !byId.has(id)) { unmatched.push({ src, row: i + 2, name, plate: norm(r[C.plate]), vin: vinOf(r[C.vin]), exp, badId: id }); return; }
  const u = id ? byId.get(id) : byName.get(key(r[C.fn] + r[C.ln]));
  if (!u) { unmatched.push({ src, row: i + 2, name, plate: norm(r[C.plate]), vin: vinOf(r[C.vin]), exp }); return; }
  out.push({ empId: u.empId, name, plate: norm(r[C.plate]).slice(0, 20), vin: vinOf(r[C.vin]), exp, byId: !!id });
});
}
/* รถคันเดียวกันมาจากหลายไฟล์ → เก็บแถวเดียว (แถวที่ระบุรหัสพนักงานเองชนะ) · แถวที่ไม่ตรงแต่อีกไฟล์จับคู่ได้แล้ว = ไม่ค้าง */
const carKey = (o) => o.vin || o.plate.replace(/[\s.-]/g, '');
{ const keep = new Map();
  for (const o of out) { const k = carKey(o); const c = keep.get(k); if (!c || (o.byId && !c.byId)) keep.set(k, o); }
  out.length = 0; out.push(...keep.values());
  const seen = new Set();
  const skip = new Set(skipped.map(carKey));
  const left = unmatched.filter((u) => { const k = carKey(u); if (keep.has(k) || skip.has(k) || seen.has(k)) return false; seen.add(k); return true; });
  unmatched.length = 0; unmatched.push(...left); }
out.sort((a, b) => a.empId.localeCompare(b.empId) || a.exp.localeCompare(b.exp));

const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";
const sql = [
  '-- กรมธรรม์ของพนักงานที่ยังไม่หมดอายุ (ใช้ตัดสินสิทธิ์รถคันที่ 2)',
  '-- สร้างโดย scripts/export-active-policy.cjs เมื่อ ' + new Date().toLocaleString('th-TH'),
  '-- ที่มา: ' + SRCS.map((f) => path.basename(f)).join(' + ') + ' · จับคู่ได้ ' + out.length + ' คัน (' + new Set(out.map((o) => o.empId)).size + ' คน)'
    + ' · ไม่พบชื่อในทำเนียบ ' + unmatched.length + ' แถว',
  '-- ⚠️ ต้องรัน migrate-2026-09-19-active-policy.sql ก่อน · รันซ้ำได้ (แทนชุดเดิมที่มาจาก Excel ทั้งหมด)',
  '',
  'begin;',
  "delete from public.ins_active_policy where source = 'excel';",
  out.length ? 'insert into public.ins_active_policy (emp_id, plate, vin, expire_on, source) values\n'
    + out.map((o) => '  (' + [q(o.empId), q(o.plate), q(o.vin), q(o.exp), q('excel')].join(', ') + ')').join(',\n') + ';' : '',
  'commit;',
  '',
  "select count(*) as policies, count(distinct emp_id) as employees,",
  "       count(*) filter (where expire_on >= (now() at time zone 'Asia/Bangkok')::date) as active_now",
  "  from public.ins_active_policy where source = 'excel';",
  '',
].join('\n');
fs.writeFileSync(OUT, sql, 'utf8');

console.log('แถวในไฟล์: ' + total);
console.log('จับคู่พนักงานได้: ' + out.length + ' คัน · ' + new Set(out.map((o) => o.empId)).size + ' คน');
console.log('ไม่พบชื่อในทำเนียบ: ' + unmatched.length + ' แถว · ตั้งใจไม่นับ: ' + new Set(skipped.map(carKey)).size + ' คัน · วันที่อ่านไม่ได้: ' + badDate.length + ' แถว');
console.log('เขียนไฟล์: ' + OUT);
if (REPORT) fs.writeFileSync(REPORT, JSON.stringify({ out, unmatched, skipped, badDate }, null, 1), 'utf8');
