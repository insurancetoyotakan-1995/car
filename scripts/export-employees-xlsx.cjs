/* สร้างไฟล์ SQL นำ "ทำเนียบพนักงานจาก Excel" เข้า Supabase — ใช้กับแบรนด์ที่ไม่ได้อยู่ในระบบใบสำคัญจ่าย
 *
 *   โตโยต้า  → scripts/export-employees.cjs  (อ่านจากฐาน voucher.db โดยตรง)
 *   ฮีโน่    → ไฟล์นี้                        (อ่านจาก Excel ที่ฝ่ายบุคคลส่งมา)
 *
 * ⚠️ ส่งขึ้นคลาวด์เฉพาะ 3 อย่าง: รหัสพนักงาน · ชื่อ-สกุล · แผนก   (ไม่มีเงินเดือน ตำแหน่ง เบอร์ เลขบัตร)
 * 🔑 รหัสพนักงานของ 2 บริษัทซ้ำกันได้และเป็นคนละคน → ทุกแถวต้องมี brand เสมอ
 *    กุญแจหลักของตาราง employees คือ (brand, emp_id) — ดู supabase/migrate-2026-09-21-brand.sql
 *
 * วิธีใช้:
 *   node scripts/export-employees-xlsx.cjs --brand hino --file "Z:\...\รายชื่อพนักงาน ปี 69_งานประกัน.xlsx"
 *
 * ผลลัพธ์: supabase/employees-<brand>.sql → เอาไปวางใน SQL Editor ของ Supabase แล้ว Run
 *          (ไฟล์อยู่ใน .gitignore — เป็นข้อมูลบุคคล ห้ามขึ้น repo สาธารณะ)
 */
const fs = require('fs');
const path = require('path');
const XLSX = require(path.join('C:', 'Users', 'dmk-006', '.claude', 'backups', 'backend', 'public', 'xlsx.full.min.js'));

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf('--' + name); return i === -1 ? def : args[i + 1]; };

const BRAND = String(opt('brand', 'hino')).toLowerCase();
const FILE = opt('file', '');
if (!['toyota', 'hino'].includes(BRAND)) { console.error('--brand ต้องเป็น toyota หรือ hino'); process.exit(1); }
if (!FILE || !fs.existsSync(FILE)) { console.error('ไม่พบไฟล์ Excel: ' + FILE); process.exit(1); }

const OUT = path.join(__dirname, '..', 'supabase', 'employees-' + BRAND + '.sql');

/* หัวตารางอยู่แถวไหนก็ได้ — มองหาแถวที่มีทั้งคำว่า "รหัส" และ "ชื่อ" แล้วเริ่มอ่านแถวถัดไป */
const wb = XLSX.read(fs.readFileSync(FILE), { type: 'buffer' });
const grid = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '', raw: false });
const head = grid.findIndex((r) => r.some((c) => /รหัส/.test(c)) && r.some((c) => /ชื่อ/.test(c)));
if (head === -1) { console.error('หาแถวหัวตารางไม่เจอ (ต้องมีคอลัมน์ "รหัส" และ "ชื่อ")'); process.exit(1); }

const col = (re) => grid[head].findIndex((c) => re.test(String(c)));
const cId = col(/รหัส/), cFirst = col(/^\s*ชื่อ/), cLast = col(/สกุล/), cDept = col(/แผนก|ฝ่าย/);

const seen = new Map();
const dup = [];
for (const row of grid.slice(head + 1)) {
  const id = String(row[cId] ?? '').trim();
  if (!id) continue;
  const name = [row[cFirst], cLast === -1 ? '' : row[cLast]]
    .map((x) => String(x ?? '').trim()).filter(Boolean).join(' ');
  if (!name) continue;
  const dept = cDept === -1 ? '' : String(row[cDept] ?? '').trim();
  if (seen.has(id)) { dup.push(id + ' (' + seen.get(id).name + ' / ' + name + ')'); continue; }
  seen.set(id, { id, name, dept });
}
const rows = [...seen.values()].sort((a, b) => a.id.localeCompare(b.id, 'th'));
if (!rows.length) { console.error('ไม่พบพนักงานในไฟล์'); process.exit(1); }

// escape แบบ SQL: ' → ''  (ชื่อไทยไม่มี backslash escaping ใน Postgres string ปกติ)
const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";

const chunks = [];
for (let i = 0; i < rows.length; i += 200) chunks.push(rows.slice(i, i + 200));

const sql = [
  '-- ทำเนียบพนักงาน (' + BRAND + ') สำหรับค้นรหัสในฟอร์มขอทำประกัน',
  '-- สร้างโดย scripts/export-employees-xlsx.cjs เมื่อ ' + new Date().toLocaleString('th-TH'),
  '-- ต้นทาง: ' + FILE,
  '-- จำนวน ' + rows.length + ' คน · รันซ้ำได้ (ชื่อ/แผนกที่เปลี่ยนจะถูกอัปเดตทับ)',
  '-- ⚠️ ต้องรัน supabase/migrate-2026-09-21-brand.sql ก่อน (ตารางต้องมีคอลัมน์ brand)',
  '',
  ...chunks.map((c) =>
    'insert into public.employees (brand, emp_id, name, dept) values\n'
    + c.map((u) => '  (' + q(BRAND) + ', ' + q(u.id) + ', ' + q(u.name) + ', ' + q(u.dept) + ')').join(',\n')
    + '\non conflict (brand, emp_id) do update set name = excluded.name, dept = excluded.dept, active = true;'
  ),
  '',
  '-- คนที่อยู่ในระบบแต่หายไปจากไฟล์รอบนี้ = ปิดใช้งาน (ไม่ลบทิ้ง ใบเก่ายังอ้างถึงได้)',
  'update public.employees set active = false',
  ' where brand = ' + q(BRAND) + ' and emp_id not in (' + rows.map((u) => q(u.id)).join(', ') + ');',
  '',
].join('\n');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, sql, 'utf8');

const byDept = {};
for (const u of rows) byDept[u.dept || '(ไม่ระบุ)'] = (byDept[u.dept || '(ไม่ระบุ)'] || 0) + 1;
console.log('เขียนไฟล์: ' + OUT);
console.log('แบรนด์ ' + BRAND + ' · พนักงาน ' + rows.length + ' คน · ' + chunks.length + ' คำสั่ง insert');
if (dup.length) console.log('⚠️ รหัสซ้ำในไฟล์ (ใช้แถวแรก): ' + dup.join(', '));
const short = rows.filter((u) => u.id.length < 4);
if (short.length) console.log('⚠️ รหัสสั้นกว่า 4 ตัว: ' + short.map((u) => u.id + ' ' + u.name).join(', '));
console.log('แยกตามแผนก:');
for (const [d, n] of Object.entries(byDept).sort((a, b) => b[1] - a[1])) console.log('  ' + n + '\t' + d);
