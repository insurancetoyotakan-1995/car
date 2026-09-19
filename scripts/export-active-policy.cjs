/* สร้างไฟล์ SQL "กรมธรรม์ของพนักงานที่ยังไม่หมดอายุ" → ใช้ตัดสินสิทธิ์รถคันที่ 2
 *
 * ที่มา: Excel ของฝ่ายประกัน (คอลัมน์ ชื่อ / นามสกุล / ทะเบียน / เลขตัวถัง / วันหมดอายุ)
 *   1) จับคู่ "ชื่อ+นามสกุล" กับทำเนียบพนักงาน (ตรงทั้งชื่อ หลังตัดช่องว่างและวงเล็บหมายเหตุ · ชื่อซ้ำในทำเนียบ = ไม่เดา)
 *      ถ้าไฟล์มีคอลัมน์ "รหัสพนักงาน" และแถวนั้นกรอกไว้ → ใช้รหัสนั้นเลย (เช่น รถของคู่สมรส/บุตร ที่ชื่อไม่ตรงพนักงาน)
 *   2) วันหมดอายุในไฟล์เป็นปี พ.ศ. (9/20/69 = 20 ก.ย. 2569) → เก็บเป็น ค.ศ.
 *   3) ในระบบ: กรมธรรม์ที่ "ยังไม่เลยวันหมดอายุ" = พนักงานใช้สิทธิ์คันแรกไปแล้ว
 *      → รถคันอื่นที่ยื่นเข้ามา = รถคันที่ 2 (ทะเบียน/เลขตัวถังเดียวกัน = ต่ออายุคันเดิม ไม่นับ)
 *      เลยวันหมดอายุแล้ว = ไม่นับ (กลับมาได้สิทธิ์คันแรก)
 *
 * วิธีใช้ (อ่านอย่างเดียว ไม่แก้ฐานข้อมูลในออฟฟิศ):
 *   node scripts/export-active-policy.cjs "Z:\IT\Botbell\งานประกัน\ข้อมูลพนักงานประกันยังไม่หมดอายุ.xlsx"
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

const SRC = process.argv[2];
const DB_FILE = process.env.VOUCHER_DB || 'E:/VoucherSystem/data/voucher.db';
const OUT = path.join(__dirname, '..', 'supabase', 'ins-active-policy.sql');
const REPORT = process.env.REPORT || '';
if (!SRC || !fs.existsSync(SRC)) { console.error('ไม่พบไฟล์ Excel: ' + SRC); process.exit(1); }

const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
const key = (s) => norm(s).replace(/[(（][^)）]*[)）]/g, '').replace(/\s/g, '');

const wb = XLSX.read(fs.readFileSync(SRC), { type: 'buffer' });
const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '', raw: true });
const H = rows[0].map(norm);
const col = (n) => { const i = H.indexOf(n); if (i < 0) { console.error('ไม่พบคอลัมน์: ' + n); process.exit(1); } return i; };
const C = { fn: col('ชื่อ'), ln: col('นามสกุล'), plate: col('ทะเบียน'), vin: col('เลขตัวถัง'), exp: col('วันหมดอายุ'),
            emp: H.indexOf('รหัสพนักงาน') };                  // ไม่บังคับ

/* วันหมดอายุ: ตัวเลขวันที่ของ Excel (ปีเป็น พ.ศ.) หรือข้อความ ด/ว/ปป · ปป = 2 หลักท้ายของ พ.ศ. */
const pad = (n) => String(n).padStart(2, '0');
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

const out = [], unmatched = [], badDate = [];
rows.slice(1).forEach((r, i) => {
  const name = norm(r[C.fn] + ' ' + r[C.ln]);
  if (!norm(r[C.fn])) return;
  const exp = expDate(r[C.exp]);
  if (!exp) { badDate.push({ row: i + 2, name, v: r[C.exp] }); return; }
  const id = C.emp >= 0 ? norm(r[C.emp]).replace(/\D/g, '') : '';
  if (id && !byId.has(id)) { unmatched.push({ row: i + 2, name, plate: norm(r[C.plate]), exp, badId: id }); return; }
  const u = id ? byId.get(id) : byName.get(key(r[C.fn] + r[C.ln]));
  if (!u) { unmatched.push({ row: i + 2, name, plate: norm(r[C.plate]), exp }); return; }
  out.push({ empId: u.empId, name, plate: norm(r[C.plate]).slice(0, 20),
             vin: norm(r[C.vin]).toUpperCase().replace(/[^0-9A-Z]/g, '').slice(0, 20), exp });
});
out.sort((a, b) => a.empId.localeCompare(b.empId) || a.exp.localeCompare(b.exp));

const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";
const sql = [
  '-- กรมธรรม์ของพนักงานที่ยังไม่หมดอายุ (ใช้ตัดสินสิทธิ์รถคันที่ 2)',
  '-- สร้างโดย scripts/export-active-policy.cjs เมื่อ ' + new Date().toLocaleString('th-TH'),
  '-- ที่มา: ' + path.basename(SRC) + ' · จับคู่ได้ ' + out.length + ' คัน (' + new Set(out.map((o) => o.empId)).size + ' คน)'
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

console.log('แถวในไฟล์: ' + rows.slice(1).filter((r) => norm(r[C.fn])).length);
console.log('จับคู่พนักงานได้: ' + out.length + ' คัน · ' + new Set(out.map((o) => o.empId)).size + ' คน');
console.log('ไม่พบชื่อในทำเนียบ: ' + unmatched.length + ' แถว · วันที่อ่านไม่ได้: ' + badDate.length + ' แถว');
console.log('เขียนไฟล์: ' + OUT);
if (REPORT) fs.writeFileSync(REPORT, JSON.stringify({ out, unmatched, badDate }, null, 1), 'utf8');
