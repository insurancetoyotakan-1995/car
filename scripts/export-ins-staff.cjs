/* สร้างไฟล์ SQL รายชื่อ "เจ้าหน้าที่ประกัน" ที่เข้าหลังบ้าน (staff.html) ได้
 *
 * เลือกจากทำเนียบในออฟฟิศ: คนที่ "ตำแหน่ง" หรือ "แผนก" มีคำว่า ประกัน
 * (ทำเนียบยังไม่มีแผนกประกันแยก — คนขายประกันอยู่แผนกขาย ตำแหน่ง "เจ้าหน้าที่ขายประกันภัย")
 *
 * ⚠️ ส่งขึ้นคลาวด์แค่ รหัสพนักงาน + ชื่อ (เป็นหมายเหตุให้คนดูแลอ่านรู้เรื่อง)
 *
 * วิธีใช้ (อ่านฐานจริงแบบ read-only ไม่แก้ไขอะไร):
 *   node scripts/export-ins-staff.cjs
 *
 * ผลลัพธ์: supabase/ins-staff.sql → วางใน SQL Editor ของ Supabase แล้ว Run
 *          (อยู่ใน .gitignore — เป็นรายชื่อผู้มีสิทธิ์เข้าระบบ ไม่ควรอยู่ใน repo สาธารณะ)
 */
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const DB_FILE = process.env.VOUCHER_DB || 'E:/VoucherSystem/data/voucher.db';
const OUT = path.join(__dirname, '..', 'supabase', 'ins-staff.sql');

if (!fs.existsSync(DB_FILE)) {
  console.error('ไม่พบฐานข้อมูล: ' + DB_FILE);
  process.exit(1);
}

const db = new Database(DB_FILE, { readonly: true });
const rows = db.prepare('SELECT data FROM users').all()
  .map((r) => { try { return JSON.parse(r.data); } catch (e) { return null; } })
  .filter(Boolean)
  .filter((u) => u.empId && u.name && u.active !== false)
  .filter((u) => /ประกัน/.test(String(u.position || '') + ' ' + String(u.dept || '')))
  .map((u) => ({ empId: String(u.empId).trim(), name: String(u.name).replace(/\s+/g, ' ').trim(),
                 position: String(u.position || '').trim() }))
  .sort((a, b) => a.empId.localeCompare(b.empId));
db.close();

if (!rows.length) { console.error('ไม่พบเจ้าหน้าที่ประกันในทำเนียบ'); process.exit(1); }

const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";
const sql = [
  '-- เจ้าหน้าที่ประกันที่เข้าหลังบ้าน (staff.html) ได้',
  '-- สร้างโดย scripts/export-ins-staff.cjs เมื่อ ' + new Date().toLocaleString('th-TH'),
  '-- จำนวน ' + rows.length + ' คน · รันซ้ำได้',
  '-- ⚠️ ต้องสร้างบัญชี Auth ให้แต่ละคนด้วย: อีเมล <รหัส>@staff.toyotakan + ติ๊ก Auto Confirm User',
  '',
  'insert into public.ins_staff (emp_id, note) values',
  rows.map((u) => '  (' + q(u.empId) + ', ' + q(u.name + (u.position ? ' · ' + u.position : '')) + ')').join(',\n'),
  'on conflict (emp_id) do update set note = excluded.note, active = true;',
  '',
].join('\n');

fs.writeFileSync(OUT, sql, 'utf8');
console.log('เขียนไฟล์: ' + OUT);
console.log('เจ้าหน้าที่ประกัน ' + rows.length + ' คน');
