/* สร้างไฟล์ SQL สำหรับนำรายชื่อพนักงานเข้า Supabase (ใช้ค้นชื่อจากรหัสในฟอร์ม)
 *
 * ⚠️ ส่งขึ้นคลาวด์เฉพาะ 3 อย่าง: รหัสพนักงาน · ชื่อ · แผนก
 *    ไม่ส่งรหัสผ่าน ลายเซ็น ตำแหน่ง อีเมล หรืออย่างอื่นจากทำเนียบเดิม
 *
 * วิธีใช้ (อ่านฐานจริงแบบ read-only ไม่แก้ไขอะไร):
 *   node scripts/export-employees.cjs                  → ทุกคนที่ยังใช้งานอยู่
 *   node scripts/export-employees.cjs --dept ขาย ประกัน → เฉพาะแผนกที่ชื่อมีคำเหล่านี้
 *
 * ผลลัพธ์: supabase/employees.sql  → เอาไปวางใน SQL Editor ของ Supabase แล้ว Run
 */
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const DB_FILE = process.env.VOUCHER_DB || 'E:/VoucherSystem/data/voucher.db';
const OUT = path.join(__dirname, '..', 'supabase', 'employees.sql');

const args = process.argv.slice(2);
const di = args.indexOf('--dept');
const deptFilter = di === -1 ? null : args.slice(di + 1).filter((a) => !a.startsWith('--'));

if (!fs.existsSync(DB_FILE)) {
  console.error('ไม่พบฐานข้อมูล: ' + DB_FILE);
  console.error('ถ้าไฟล์อยู่ที่อื่น ตั้งตัวแปร VOUCHER_DB ชี้ไปที่ไฟล์นั้น');
  process.exit(1);
}

const db = new Database(DB_FILE, { readonly: true });
const rows = db.prepare('SELECT data FROM users').all()
  .map((r) => { try { return JSON.parse(r.data); } catch (e) { return null; } })
  .filter(Boolean)
  .filter((u) => u.empId && u.name && u.active !== false)
  .filter((u) => !deptFilter || deptFilter.some((d) => String(u.dept || '').includes(d)))
  .map((u) => ({ empId: String(u.empId).trim(), name: String(u.name).trim(), dept: String(u.dept || '').trim() }))
  .sort((a, b) => a.empId.localeCompare(b.empId));
db.close();

if (!rows.length) { console.error('ไม่พบพนักงานที่ตรงเงื่อนไข'); process.exit(1); }

// escape แบบ SQL: ' → ''  (ชื่อไทยไม่มี backslash escaping ใน Postgres string ปกติ)
const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";

const chunks = [];
for (let i = 0; i < rows.length; i += 200) chunks.push(rows.slice(i, i + 200));

const sql = [
  '-- รายชื่อพนักงานสำหรับค้นรหัสในฟอร์มขอทำประกัน',
  '-- สร้างโดย scripts/export-employees.cjs เมื่อ ' + new Date().toLocaleString('th-TH'),
  '-- จำนวน ' + rows.length + ' คน' + (deptFilter ? ' (กรองแผนก: ' + deptFilter.join(', ') + ')' : ' (ทุกคนที่ยังใช้งานอยู่)'),
  '-- รันซ้ำได้ — ชื่อ/แผนกที่เปลี่ยนจะถูกอัปเดตทับ',
  '',
  ...chunks.map((c) =>
    /* 🔑 กุญแจหลักเป็น (brand, emp_id) ตั้งแต่ migrate-2026-09-21-brand.sql
       เพราะรหัสพนักงานโตโยต้ากับฮีโน่ซ้ำกันได้ และเป็นคนละคน */
    "insert into public.employees (brand, emp_id, name, dept) values\n"
    + c.map((u) => "  ('toyota', " + q(u.empId) + ', ' + q(u.name) + ', ' + q(u.dept) + ')').join(',\n')
    + '\non conflict (brand, emp_id) do update set name = excluded.name, dept = excluded.dept, active = true;'
  ),
  '',
].join('\n');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, sql, 'utf8');

const byDept = {};
for (const u of rows) byDept[u.dept || '(ไม่ระบุ)'] = (byDept[u.dept || '(ไม่ระบุ)'] || 0) + 1;
console.log('เขียนไฟล์: ' + OUT);
console.log('พนักงาน ' + rows.length + ' คน · ' + chunks.length + ' คำสั่ง insert');
console.log('แยกตามแผนก:');
for (const [d, n] of Object.entries(byDept).sort((a, b) => b[1] - a[1])) console.log('  ' + n + '\t' + d);
