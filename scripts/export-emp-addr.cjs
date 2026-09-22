/* สร้างไฟล์ SQL "ที่อยู่พนักงาน" จาก Excel ของฝ่ายประกัน
 *
 * ที่มา: คอลัมน์ ชื่อ / นามสกุล / บ้านเลขที่ / ถนน / หมู่ / ตำบล / อำเภอ / จังหวัด / เลขไปรษณีย์
 *   จับคู่ชื่อ→รหัสพนักงาน ด้วยกติกาเดียวกับ export-active-policy.cjs
 *   (ตรงทั้งชื่อหลังตัดช่องว่าง/วงเล็บ · ชื่อซ้ำในทำเนียบ = ไม่เดา · มีคอลัมน์ "รหัสพนักงาน" ก็ใช้ตัวนั้นก่อน)
 *
 * ปรับข้อมูลให้เข้ารูปฟอร์ม 3 อย่าง (รายงานให้ดูทุกแถวที่แก้)
 *   1) หมู่ "ม.3" → "3"        — ช่องหมู่ในฟอร์มใช้เฉพาะเลข (ใช้หาเลขไปรษณีย์)
 *   2) อำเภอ "เมือง" → "เมือง<จังหวัด>" — ให้ตรงกับชุดข้อมูลไปรษณีย์ (th-zip.json)
 *   3) เบอร์โทร "861742037" → "0861742037" — Excel มองเป็นตัวเลข เลข 0 หน้าจึงหาย
 *
 * วิธีใช้ (อ่านอย่างเดียว ไม่แก้ฐานข้อมูลในออฟฟิศ):
 *   node scripts/export-emp-addr.cjs "Z:\IT\Botbell\งานประกัน\ข้อมูลพนักงานประกันยังไม่หมดอายุ.xlsx"
 *
 * ผลลัพธ์: supabase/ins-emp-addr.sql (อยู่ใน .gitignore) → วางใน SQL Editor แล้ว Run
 * 🔒 ที่อยู่ + เบอร์โทรพนักงาน = ข้อมูลส่วนบุคคล · อ่านได้เฉพาะเจ้าหน้าที่ประกัน (ins_addr_of)
 *    ไม่ส่งชื่อ ไม่ส่งทะเบียนรถ ไปกับตารางนี้
 *    ⚠️ เบอร์โทรไม่อยู่ใน ins_addr_pub ที่ฟอร์มสาธารณะเรียก — เห็นได้เฉพาะคนที่ล็อกอิน
 */
const fs = require('fs');
const path = require('path');
const BACKEND = 'C:/Users/dmk-006/.claude/backups/backend';
const XLSX = require(BACKEND + '/public/xlsx.full.min.js');
const Database = require(BACKEND + '/node_modules/better-sqlite3');

const SRCS = process.argv.slice(2);
const DB_FILE = process.env.VOUCHER_DB || 'E:/VoucherSystem/data/voucher.db';
const OUT = path.join(__dirname, '..', 'supabase', 'ins-emp-addr.sql');
if (!SRCS.length) { console.error('ระบุไฟล์ Excel อย่างน้อย 1 ไฟล์'); process.exit(1); }
for (const f of SRCS) if (!fs.existsSync(f)) { console.error('ไม่พบไฟล์ Excel: ' + f); process.exit(1); }

const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
const key = (s) => norm(s).replace(/[(（][^)）]*[)）]/g, '').replace(/\s/g, '');

const db = new Database(DB_FILE, { readonly: true });
const users = db.prepare('SELECT data FROM users').all()
  .map((r) => { try { return JSON.parse(r.data); } catch (e) { return null; } })
  .filter((u) => u && u.empId && u.name && u.active !== false);
db.close();
const byName = new Map();
for (const u of users) { const k = key(u.name); byName.set(k, byName.has(k) ? null : u); }
const byId = new Map(users.map((u) => [String(u.empId), u]));

const fixed = [], unmatched = [], noAddr = [];
const rowsOut = new Map();                                 // emp_id → ที่อยู่ (แถวหลังชนะ)
let total = 0;

for (const file of SRCS) {
  const wb = XLSX.read(fs.readFileSync(file), { type: 'buffer' });
  const grid = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '', raw: false });
  const H = grid[0].map(norm);
  const col = (n, req) => {
    const i = H.indexOf(n);
    if (i < 0 && req) { console.error(path.basename(file) + ' ไม่พบคอลัมน์: ' + n); process.exit(1); }
    return i;
  };
  const C = { fn: col('ชื่อ', 1), ln: col('นามสกุล', 1), addr: col('บ้านเลขที่', 1), road: col('ถนน', 1),
              moo: col('หมู่', 1), tambon: col('ตำบล', 1), amphoe: col('อำเภอ', 1),
              province: col('จังหวัด', 1), zip: col('เลขไปรษณีย์', 1),
              phone: H.indexOf('เบอร์โทรศัพท์'), emp: H.indexOf('รหัสพนักงาน') };
  const src = path.basename(file);

  grid.slice(1).forEach((r, i) => {
    if (!norm(r[C.fn])) return;
    total++;
    const name = norm(r[C.fn] + ' ' + r[C.ln]);
    if (C.emp >= 0 && norm(r[C.emp]) === 'ไม่นับ') return;
    const id0 = C.emp >= 0 ? norm(r[C.emp]).replace(/\D/g, '') : '';
    const u = id0 ? byId.get(id0) : byName.get(key(r[C.fn] + r[C.ln]));
    if (!u) { unmatched.push({ src, row: i + 2, name }); return; }

    const province = norm(r[C.province]);
    // หมู่: "ม.3" / "หมู่ 3" → "3"
    let moo = norm(r[C.moo]);
    const moo0 = moo;
    moo = moo.replace(/^(?:ม\.?|หมู่)\s*/, '').trim();
    if (moo !== moo0) fixed.push({ name, what: 'หมู่', from: moo0, to: moo });
    // อำเภอ: "เมือง" เดี่ยว ๆ → "เมือง<จังหวัด>" ให้ตรงชุดข้อมูลไปรษณีย์
    let amphoe = norm(r[C.amphoe]);
    if (amphoe === 'เมือง' && province) { fixed.push({ name, what: 'อำเภอ', from: amphoe, to: 'เมือง' + province }); amphoe = 'เมือง' + province; }

    /* เบอร์โทร: Excel เก็บเป็นตัวเลข เลข 0 หน้าหาย → 9 หลักขึ้นต้น 6/8/9 เติม 0 คืน
       ยาวไม่ครบ 10 หลัก = ไม่เก็บ ดีกว่าเก็บเบอร์ที่โทรไม่ติด */
    let phone = C.phone >= 0 ? norm(r[C.phone]).replace(/[^0-9]/g, '') : '';
    if (phone.length === 9 && /^[689]/.test(phone)) {
      fixed.push({ name, what: 'เบอร์โทร', from: phone, to: '0' + phone });
      phone = '0' + phone;
    }
    if (phone.length !== 10) phone = '';
    const a = { empId: String(u.empId), name, phone,
                addr: norm(r[C.addr]).slice(0, 80), moo: moo.slice(0, 20), road: norm(r[C.road]).slice(0, 60),
                tambon: norm(r[C.tambon]).slice(0, 60), amphoe: amphoe.slice(0, 60),
                province: province.slice(0, 60), zipcode: norm(r[C.zip]).replace(/\D/g, '').slice(0, 5) };
    if (!a.addr && !a.tambon) { noAddr.push({ src, row: i + 2, name }); return; }
    rowsOut.set(a.empId, a);                               // คนเดิมหลายแถว (หลายคัน) = ที่อยู่ชุดเดียว
  });
}

const out = [...rowsOut.values()].sort((a, b) => a.empId.localeCompare(b.empId));
if (!out.length) { console.error('จับคู่ที่อยู่ไม่ได้เลย'); process.exit(1); }

const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";
const sql = [
  '-- ที่อยู่พนักงาน (จาก Excel ฝ่ายประกัน) — ใช้ให้เจ้าหน้าที่คีย์ใบไม่ต้องพิมพ์ที่อยู่ซ้ำ',
  '-- สร้างโดย scripts/export-emp-addr.cjs เมื่อ ' + new Date().toLocaleString('th-TH'),
  '-- ที่มา: ' + SRCS.map((f) => path.basename(f)).join(' + '),
  '-- จับคู่ได้ ' + out.length + ' คน จาก ' + total + ' แถว · ไม่พบชื่อในทำเนียบ ' + unmatched.length + ' แถว',
  '-- ⚠️ ต้องรัน migrate-2026-09-22-renewal.sql ก่อน (ต้องมีคอลัมน์ phone_mobile) · รันซ้ำได้',
  '-- 🔒 ข้อมูลส่วนบุคคล — ไฟล์นี้อยู่ใน .gitignore ห้ามขึ้น repo สาธารณะ',
  '',
  'begin;',
  "delete from public.ins_emp_addr where source = 'excel' and brand = 'toyota';",
  'insert into public.ins_emp_addr (brand, emp_id, addr, moo, road, tambon, amphoe, province, zipcode, phone_mobile, source) values',
  out.map((o) => "  ('toyota', " + [o.empId, o.addr, o.moo, o.road, o.tambon, o.amphoe, o.province, o.zipcode, o.phone, 'excel']
    .map(q).join(', ') + ')').join(',\n') + '\non conflict (brand, emp_id) do update set'
    + '\n  addr = excluded.addr, moo = excluded.moo, road = excluded.road, tambon = excluded.tambon,'
    + '\n  amphoe = excluded.amphoe, province = excluded.province, zipcode = excluded.zipcode,'
    + '\n  phone_mobile = excluded.phone_mobile,'
    + '\n  source = excluded.source, updated_at = now();',
  'commit;',
  '',
  "select count(*) as addresses from public.ins_emp_addr where source = 'excel';",
  '',
].join('\n');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, sql, 'utf8');

console.log('เขียนไฟล์: ' + OUT);
console.log('ที่อยู่ที่จับคู่ได้: ' + out.length + ' คน (จาก ' + total + ' แถว)');
if (fixed.length) {
  console.log('\nปรับรูปแบบให้ ' + fixed.length + ' จุด:');
  for (const f of fixed) console.log('  ' + f.name + ' · ' + f.what + ': "' + f.from + '" → "' + f.to + '"');
}
if (noAddr.length) {
  console.log('\n⚠️ ไม่มีที่อยู่ในไฟล์ ' + noAddr.length + ' แถว (ข้าม):');
  for (const u of noAddr) console.log('  แถว ' + u.row + ' · ' + u.name);
}
if (unmatched.length) {
  console.log('\n⚠️ ไม่พบชื่อในทำเนียบ ' + unmatched.length + ' แถว (ข้าม — เติมคอลัมน์ "รหัสพนักงาน" ในไฟล์ช่วยได้):');
  for (const u of unmatched) console.log('  แถว ' + u.row + ' · ' + u.name);
}
