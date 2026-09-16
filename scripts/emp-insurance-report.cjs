/* รายงาน "พนักงานที่เคยทำประกันรถกับเรา" → ไฟล์ Excel 4 ชีต
 *
 *   node scripts/emp-insurance-report.cjs "<ไฟล์ Excel ฝ่ายประกัน.xlsx>" ["<ปลายทาง.xlsx>"] ["<ไฟล์รายชื่อยืนยัน.xlsx>"]
 *
 * ที่มา (อ่านอย่างเดียวทั้งหมด ไม่แก้อะไรเลย):
 *   1) ไฟล์ Excel รายการกรมธรรม์ของฝ่ายประกัน — คอลัมน์ ชื่อ/นามสกุล/ทะเบียน/วันหมดอายุ/ประเภทลูกค้า/พนักงานขาย ฯลฯ
 *   2) ทำเนียบพนักงานจาก voucher.db (readonly)
 *   3) supabase/ins-emp-owner.sql ถ้ามี → คอลัมน์ "ผู้ดูแลในระบบใหม่"
 *   4) (ออปชัน) ไฟล์รายชื่อยืนยันจากฝ่ายประกัน — คอลัมน์ ชื่อ/นามสกุล/วันหมดอายุ → ติ๊กคอลัมน์ "อยู่ในไฟล์ยืนยัน"
 *
 * 🔑 ใครคือ "พนักงาน" — ใช้ 2 สัญญาณ แล้วแยกกลุ่มให้ชัด ไม่ยุบรวมกัน:
 *    ① ป้าย "ประเภทลูกค้า" ที่ฝ่ายประกันติดไว้ว่าพนักงาน   ② จับคู่ ชื่อ+นามสกุล กับทำเนียบ
 *    ติดป้ายพนักงานแต่ไม่อยู่ในทำเนียบ = ญาติ/คนที่ลาออก → แยกไปชีต "ต้องยืนยัน" ห้ามนับเป็นพนักงาน
 *
 * ⚠️ วันที่ในไฟล์ต้นทางเป็น serial ที่คนกรอกพิมพ์เป็น พ.ศ. → ถอด 543 ปีออก
 * ⚠️ XLSX build ที่ใช้เป็น standalone ไม่ผูก fs → ต้อง XLSX.write + fs.writeFileSync (writeFile ขึ้น cannot save file)
 */
const fs = require('fs'), path = require('path');
const B = 'C:/Users/dmk-006/.claude/backups/backend';
const XLSX = require(B + '/public/xlsx.full.min.js');
const Database = require(B + '/node_modules/better-sqlite3');

const SRC = process.argv[2];
const CONFIRM = process.argv[4] || '';
const DB_FILE = process.env.VOUCHER_DB || 'E:/VoucherSystem/data/voucher.db';
if (!SRC || !fs.existsSync(SRC)) {
  console.error('ไม่พบไฟล์ Excel: ' + SRC);
  console.error('วิธีใช้: node scripts/emp-insurance-report.cjs "<ไฟล์.xlsx>" ["<ปลายทาง.xlsx>"] ["<ไฟล์รายชื่อยืนยัน.xlsx>"]');
  process.exit(1);
}
const TODAY = new Date(); TODAY.setHours(0, 0, 0, 0);
const stamp = TODAY.getFullYear() + '-' + String(TODAY.getMonth() + 1).padStart(2, '0') + '-' + String(TODAY.getDate()).padStart(2, '0');
const OUT = process.argv[3] || path.join(require('os').homedir(), 'Desktop', 'ประกันพนักงาน-' + stamp + '.xlsx');

const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
// ตัดวงเล็บหมายเหตุ เช่น "สุจิตรา(พนักงาน)" แล้วเอาช่องว่างออก (ชื่อในทำเนียบหลายคนมีเว้นวรรค 2 ครั้ง)
const keyOf = (s) => norm(s).replace(/[(（][^)）]*[)）]/g, '').replace(/\s/g, '');
// ตัดสระ/วรรณยุกต์ออก = เทียบโครงพยัญชนะ ใช้จับชื่อที่สะกดต่างเล็กน้อย (โค้วสกุล vs โค้วสุกล)
const skelOf = (s) => keyOf(s).replace(/[\u0E31\u0E34-\u0E3A\u0E47-\u0E4E]/g, '');

const wb = XLSX.read(fs.readFileSync(SRC), { type: 'buffer' });
const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '' });
const H = rows[0].map(norm);
const ci = (n) => { const i = H.indexOf(n); if (i < 0) { console.error('ไม่พบคอลัมน์: ' + n); process.exit(1); } return i; };
const C = {
  fn: ci('ชื่อ'), ln: ci('นามสกุล'), plate: ci('ทะเบียน'), yr: ci('ปีรถ'), model: ci('รุ่น'),
  comp: ci('บริษัทประกัน'), cap: ci('ทุนประกัน'), prem: ci('เบี้ยรวม'), no: ci('เลขกรมธรรม์'),
  exp: ci('วันหมดอายุ'), at: ci('วันที่แจ้ง'), typ: ci('ประเภท'), sale: ci('พนักงานขาย'),
  st: ci('สถานะกรมธรรม์'), ctyp: ci('ประเภทลูกค้า'), tel: ci('เบอร์โทรศัพท์'),
};

const db = new Database(DB_FILE, { readonly: true });
const users = db.prepare('SELECT data FROM users').all()
  .map((r) => { try { return JSON.parse(r.data); } catch (e) { return null; } })
  .filter((u) => u && u.empId && u.name && u.active !== false);
db.close();
const byId = new Map(users.map((u) => [u.empId, u]));
const byName = new Map(), bySkel = new Map(), byLast = new Map();
for (const u of users) {
  const k = keyOf(u.name); byName.set(k, byName.has(k) ? null : u);          // ชื่อซ้ำในทำเนียบ = ไม่เดา
  const s = skelOf(u.name); bySkel.set(s, bySkel.has(s) ? null : u);
  const p = norm(u.name).split(' ').filter(Boolean);
  const lk = keyOf(p[p.length - 1]);
  const arr = byLast.get(lk) || []; arr.push(u); byLast.set(lk, arr);
}

const owner = new Map();
try {
  const sql = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'ins-emp-owner.sql'), 'utf8');
  for (const m of sql.matchAll(/\('(\d+)',\s*'(\d+)'/g)) owner.set(m[1], m[2]);
} catch (e) {}

// รายชื่อยืนยันจากฝ่ายประกัน (ออปชัน)
const confirmSet = new Set();
if (CONFIRM && fs.existsSync(CONFIRM)) {
  const cw = XLSX.read(fs.readFileSync(CONFIRM), { type: 'buffer' });
  const cr = XLSX.utils.sheet_to_json(cw.Sheets[cw.SheetNames[0]], { header: 1, defval: '' });
  const ch = cr[0].map(norm);
  let fi = ch.indexOf('ชื่อ'), li = ch.indexOf('นามสกุล');
  if (fi < 0) { fi = 1; li = 2; }                                            // ไฟล์บางฉบับหัวคอลัมน์ไม่ตรง
  cr.slice(1).forEach((r) => { if (norm(r[fi])) confirmSet.add(keyOf(r[fi] + r[li])); });
  console.log('รายชื่อยืนยัน: ' + confirmSet.size + ' ชื่อ จาก ' + path.basename(CONFIRM));
}

const toDate = (v) => {
  const n = Number(v); if (!n || n < 1000) return null;
  const t = new Date(Date.UTC(1899, 11, 30) + n * 86400000);
  const y = t.getUTCFullYear() - 543; if (y < 1990 || y > 2100) return null;
  return new Date(y, t.getUTCMonth(), t.getUTCDate());
};
const th = (d) => d ? String(d.getDate()).padStart(2, '0') + '/' + String(d.getMonth() + 1).padStart(2, '0') + '/' + (d.getFullYear() + 543) : '';
const days = (d) => d ? Math.round((d - TODAY) / 86400000) : null;
const tel = (s) => { const t = norm(s).replace(/[^\d]/g, ''); return !t ? '' : (t.length === 9 ? '0' + t : t); };
const money = (v) => { const n = Number(String(v).replace(/,/g, '')); return isFinite(n) && n ? n : ''; };
const isEmpTag = (t) => /พนักงาน/.test(t);

// ---- อ่านทุกแถว แล้วแยกกลุ่ม
const byPerson = new Map();                     // key ชื่อ → { key, fn, ln, u, tagged, list[] }
rows.slice(1).forEach((r) => {
  if (!norm(r[C.fn])) return;
  const k = keyOf(r[C.fn] + r[C.ln]);
  const tagged = isEmpTag(norm(r[C.ctyp]));
  const u = byName.get(k) || bySkel.get(skelOf(r[C.fn] + r[C.ln])) || null;
  if (!tagged && !u) return;                    // ไม่ติดป้ายพนักงาน และไม่อยู่ในทำเนียบ = ลูกค้าทั่วไป ข้าม
  const o = byPerson.get(k) || { key: k, fn: norm(r[C.fn]), ln: norm(r[C.ln]), u, tagged: false, list: [] };
  if (tagged) o.tagged = true;
  if (!o.u && u) o.u = u;
  o.list.push({
    plate: norm(r[C.plate]), yr: norm(r[C.yr]), model: norm(r[C.model]), comp: norm(r[C.comp]),
    cap: money(r[C.cap]), prem: money(r[C.prem]), no: norm(r[C.no]), exp: toDate(r[C.exp]),
    at: toDate(r[C.at]), typ: norm(r[C.typ]), sale: norm(r[C.sale]), st: norm(r[C.st]),
    ctyp: norm(r[C.ctyp]), tel: tel(r[C.tel]),
  });
  byPerson.set(k, o);
});

const GROUP = {
  both: 'พนักงาน (ยืนยัน 2 ทาง)',
  dirOnly: 'พนักงาน (ชื่อตรงทำเนียบ · ไฟล์ติดป้ายลูกค้า)',
  tagOnly: 'ติดป้ายพนักงาน แต่ไม่มีในทำเนียบ',
};
const all = [...byPerson.values()].map((o) => {
  const L = o.list.slice().sort((a, b) => (b.exp ? +b.exp : 0) - (a.exp ? +a.exp : 0))[0];   // ฉบับที่หมดช้าสุด
  const dd = days(L.exp);
  const status = dd == null ? 'ไม่ทราบวันหมดอายุ'
    : dd < 0 ? 'หมดอายุแล้ว ' + (-dd) + ' วัน'
    : dd === 0 ? 'หมดอายุวันนี้' : 'เหลือ ' + dd + ' วัน';
  const group = o.u ? (o.tagged ? GROUP.both : GROUP.dirOnly) : GROUP.tagOnly;
  // คนที่ไม่อยู่ในทำเนียบ: นามสกุลตรงกับพนักงานคนไหน (เบาะแสว่าเป็นญาติของใคร)
  const rel = o.u ? [] : (byLast.get(keyOf(o.ln)) || []).map((u) => norm(u.name) + ' (' + u.empId + ')');
  return { ...o, L, dd, status, group, rel, inConfirm: confirmSet.size ? confirmSet.has(o.key) : null };
});
const cmpExp = (a, b) => {
  const ea = a.dd != null && a.dd < 0, eb = b.dd != null && b.dd < 0;
  if (ea !== eb) return ea ? 1 : -1;            // ยังไม่หมดอายุขึ้นก่อน
  if (a.dd == null) return 1; if (b.dd == null) return -1;
  return ea ? b.dd - a.dd : a.dd - b.dd;        // ยังไม่หมด: ใกล้สุดก่อน · หมดแล้ว: หมดล่าสุดก่อน
};
const staff = all.filter((p) => p.u).sort(cmpExp);
const outsiders = all.filter((p) => !p.u).sort(cmpExp);

const ownerName = (id) => { const a = owner.get(id); if (!a) return ''; const u = byId.get(a); return u ? norm(u.name) + ' (' + a + ')' : a; };
const yn = (v) => v == null ? '' : (v ? 'อยู่' : 'ไม่อยู่');

// ---- ชีต 1: พนักงาน 1 คน 1 บรรทัด
const H1 = ['รหัสพนักงาน', 'ชื่อ-นามสกุล', 'แผนก', 'ตำแหน่ง', 'กลุ่ม', 'สถานะประกัน', 'เหลืออีก (วัน)', 'วันหมดอายุ',
  'ทะเบียน', 'ปีรถ', 'รุ่น', 'บริษัทประกัน', 'ประเภท', 'เบี้ยรวม', 'เบอร์โทร', 'ผู้ขายเดิม',
  'ผู้ดูแลในระบบใหม่', 'จำนวนกรมธรรม์', 'ป้ายในไฟล์', 'อยู่ในไฟล์ยืนยัน', 'หมายเหตุจากไฟล์'];
const A1 = [H1].concat(staff.map((p) => [p.u.empId, norm(p.u.name), p.u.dept || '', p.u.position || '', p.group,
  p.status, p.dd == null ? '' : p.dd, th(p.L.exp), p.L.plate, p.L.yr, p.L.model, p.L.comp, p.L.typ,
  p.L.prem, p.L.tel, p.L.sale, ownerName(p.u.empId), p.list.length, p.L.ctyp, yn(p.inConfirm), p.L.st]));

// ---- ชีต 2: ทุกกรมธรรม์ (ทั้งพนักงานและกลุ่มต้องยืนยัน)
const H2 = ['กลุ่ม', 'รหัสพนักงาน', 'ชื่อ-นามสกุล', 'ทะเบียน', 'ปีรถ', 'รุ่น', 'บริษัทประกัน', 'ประเภท', 'เลขกรมธรรม์',
  'วันที่แจ้ง', 'วันหมดอายุ', 'เหลืออีก (วัน)', 'ทุนประกัน', 'เบี้ยรวม', 'ผู้ขาย', 'ป้ายในไฟล์', 'เบอร์โทร', 'สถานะ/หมายเหตุ'];
const det = [];
for (const p of staff.concat(outsiders))
  for (const x of p.list.slice().sort((a, b) => (b.exp ? +b.exp : 0) - (a.exp ? +a.exp : 0)))
    det.push([p.group, p.u ? p.u.empId : '', p.u ? norm(p.u.name) : (p.fn + ' ' + p.ln).trim(), x.plate, x.yr, x.model,
      x.comp, x.typ, x.no, th(x.at), th(x.exp), days(x.exp) == null ? '' : days(x.exp), x.cap, x.prem,
      x.sale, x.ctyp, x.tel, x.st]);
const A2 = [H2].concat(det);

// ---- ชีต 3: ติดป้ายพนักงาน แต่ไม่มีในทำเนียบ
const H3 = ['ชื่อ-นามสกุล (ตามไฟล์)', 'สถานะประกัน', 'เหลืออีก (วัน)', 'วันหมดอายุ', 'ทะเบียน', 'รุ่น', 'บริษัทประกัน',
  'เบี้ยรวม', 'เบอร์โทร', 'ผู้ขายเดิม', 'จำนวนกรมธรรม์', 'นามสกุลตรงกับพนักงาน', 'อยู่ในไฟล์ยืนยัน', 'หมายเหตุจากไฟล์'];
const A3 = [H3].concat(outsiders.map((p) => [(p.fn + ' ' + p.ln).trim(), p.status, p.dd == null ? '' : p.dd, th(p.L.exp),
  p.L.plate, p.L.model, p.L.comp, p.L.prem, p.L.tel, p.L.sale, p.list.length,
  p.rel.join(' · '), yn(p.inConfirm), p.L.st]));

// ---- ชีต 4: สรุป
const n = (arr, f) => arr.filter(f).length;
const g = (name) => staff.filter((p) => p.group === name).length;
const A4 = [['สรุป: พนักงานที่เคยทำประกันรถกับเรา'], [],
  ['ข้อมูล ณ วันที่', th(TODAY)],
  ['ที่มา', path.basename(SRC) + '  (ชีต ' + wb.SheetNames[0] + ')'],
  CONFIRM ? ['ไฟล์รายชื่อยืนยัน', path.basename(CONFIRM) + '  (' + confirmSet.size + ' ชื่อ)'] : ['ไฟล์รายชื่อยืนยัน', '(ไม่ได้ใส่)'],
  [], ['— พนักงาน (ชีต "พนักงาน") —'],
  ['รวม (คน)', staff.length],
  ['  ' + GROUP.both, g(GROUP.both)],
  ['  ' + GROUP.dirOnly, g(GROUP.dirOnly)],
  ['กรมธรรม์ของพนักงาน (ฉบับ)', staff.reduce((s, p) => s + p.list.length, 0)], [],
  ['หมดอายุภายใน 30 วัน', n(staff, (p) => p.dd != null && p.dd >= 0 && p.dd <= 30)],
  ['หมดอายุใน 31-90 วัน', n(staff, (p) => p.dd != null && p.dd > 30 && p.dd <= 90)],
  ['เหลือเกิน 90 วัน', n(staff, (p) => p.dd != null && p.dd > 90)],
  ['ฉบับล่าสุดหมดอายุไปแล้ว', n(staff, (p) => p.dd != null && p.dd < 0)], [],
  ['— ต้องยืนยัน (ชีต "ต้องยืนยัน") —'],
  ['ติดป้ายพนักงานแต่ไม่มีในทำเนียบ (ชื่อ)', outsiders.length],
  ['  ในนั้น นามสกุลตรงกับพนักงาน (น่าจะเป็นญาติ)', n(outsiders, (p) => p.rel.length)],
  ['  ไม่มีทั้งชื่อและนามสกุลในทำเนียบ', n(outsiders, (p) => !p.rel.length)], [],
  ['⚠️ ข้อควรระวัง'],
  ['1', 'ไฟล์ต้นทางเป็นรายการกรมธรรม์ "ที่หมดอายุในปีนั้น" ไม่ใช่ประวัติทั้งหมด → คนที่ไม่มีชื่อ อาจทำประกันไว้แต่หมดอายุปีอื่น'],
  ['2', '"หมดอายุแล้ว" = ฉบับที่ซื้อกับเราหมดแล้ว ไม่ได้แปลว่าไม่มีประกัน (อาจไปต่อที่อื่น ซึ่งไม่มีบันทึกในไฟล์นี้)'],
  ['3', 'ชีต "ต้องยืนยัน" = ฝ่ายประกันติดป้ายว่าพนักงาน แต่ชื่อไม่อยู่ในทำเนียบ → ส่วนใหญ่เป็นคนในครอบครัว (ดูคอลัมน์ "นามสกุลตรงกับพนักงาน") หรือคนที่ลาออกไปแล้ว · ห้ามนับเป็นพนักงาน'],
  ['4', 'กลุ่ม "ชื่อตรงทำเนียบ · ไฟล์ติดป้ายลูกค้า" = ฝ่ายประกันไม่ได้ติดป้ายพนักงานให้ อาจเป็นคนละคนที่ชื่อ-นามสกุลตรงกันพอดี → เช็คก่อนใช้'],
  ['5', 'ไฟล์ไม่ได้แยกว่ารถเป็นของพนักงานเองหรือของคนในครอบครัว — ดูคอลัมน์ "หมายเหตุจากไฟล์" ประกอบ (บางแถวเขียนว่า รถแฟน / รถบริษัท)'],
  ['6', 'คอลัมน์ "ผู้ดูแลในระบบใหม่" มาจากตาราง ins_emp_owner ของฟอร์มออนไลน์ — ว่าง = ผู้ขายเดิมไม่ได้อยู่ในรายชื่อเจ้าหน้าที่ประกันของระบบแล้ว ระบบจะแจกใบให้คนที่ถือน้อยสุดแทน'],
  ['7', 'เรียงลำดับ: ยังไม่หมดอายุ (ใกล้สุดขึ้นก่อน) แล้วต่อด้วยที่หมดอายุไปแล้ว · จะเรียงใหม่ให้กดตัวกรองที่หัวตาราง'],
  ['8', 'สร้างใหม่: node scripts/emp-insurance-report.cjs "<ไฟล์ฝ่ายประกัน>" "" "<ไฟล์รายชื่อยืนยัน>"']];

const out = XLSX.utils.book_new();
const s1 = XLSX.utils.aoa_to_sheet(A1), s2 = XLSX.utils.aoa_to_sheet(A2),
      s3 = XLSX.utils.aoa_to_sheet(A3), s4 = XLSX.utils.aoa_to_sheet(A4);
s1['!cols'] = [{ wch: 12 }, { wch: 28 }, { wch: 20 }, { wch: 26 }, { wch: 34 }, { wch: 18 }, { wch: 12 }, { wch: 12 }, { wch: 12 }, { wch: 7 }, { wch: 16 }, { wch: 30 }, { wch: 24 }, { wch: 11 }, { wch: 12 }, { wch: 12 }, { wch: 26 }, { wch: 8 }, { wch: 16 }, { wch: 14 }, { wch: 42 }];
s2['!cols'] = [{ wch: 34 }, { wch: 12 }, { wch: 28 }, { wch: 12 }, { wch: 7 }, { wch: 16 }, { wch: 30 }, { wch: 24 }, { wch: 18 }, { wch: 12 }, { wch: 12 }, { wch: 12 }, { wch: 12 }, { wch: 11 }, { wch: 12 }, { wch: 16 }, { wch: 12 }, { wch: 42 }];
s3['!cols'] = [{ wch: 28 }, { wch: 18 }, { wch: 12 }, { wch: 12 }, { wch: 12 }, { wch: 16 }, { wch: 30 }, { wch: 11 }, { wch: 12 }, { wch: 12 }, { wch: 8 }, { wch: 40 }, { wch: 14 }, { wch: 42 }];
s4['!cols'] = [{ wch: 40 }, { wch: 120 }];
s1['!autofilter'] = { ref: 'A1:U1' };
s2['!autofilter'] = { ref: 'A1:R1' };
s3['!autofilter'] = { ref: 'A1:N1' };
// รหัสพนักงาน/เลขกรมธรรม์/เบอร์โทร ต้องเป็นข้อความ ไม่งั้น Excel กินศูนย์นำหน้า
const fmt = (ws, cnt, cols, z, asText) => {
  for (let r = 1; r <= cnt; r++) for (const c of cols) {
    const a = XLSX.utils.encode_cell({ r, c });
    if (!ws[a] || ws[a].v === '' || ws[a].v == null) continue;
    if (asText) { ws[a].t = 's'; ws[a].v = String(ws[a].v); ws[a].z = '@'; }
    if (z) ws[a].z = z;
  }
};
fmt(s1, staff.length, [0, 14], null, true);   fmt(s1, staff.length, [13], '#,##0.00');
fmt(s2, det.length, [1, 8, 16], null, true);  fmt(s2, det.length, [12, 13], '#,##0.00');
fmt(s3, outsiders.length, [8], null, true);   fmt(s3, outsiders.length, [7], '#,##0.00');
XLSX.utils.book_append_sheet(out, s1, 'พนักงาน');
XLSX.utils.book_append_sheet(out, s2, 'ทุกกรมธรรม์');
XLSX.utils.book_append_sheet(out, s3, 'ต้องยืนยัน');
XLSX.utils.book_append_sheet(out, s4, 'สรุป + วิธีอ่าน');
fs.writeFileSync(OUT, XLSX.write(out, { type: 'buffer', bookType: 'xlsx' }));
console.log('เขียนไฟล์: ' + OUT);
console.log('พนักงาน ' + staff.length + ' คน (ยืนยัน 2 ทาง ' + g(GROUP.both) + ' · ชื่อตรงแต่ไม่ติดป้าย ' + g(GROUP.dirOnly) + ')'
  + ' · ต้องยืนยัน ' + outsiders.length + ' ชื่อ · กรมธรรม์รวม ' + det.length + ' ฉบับ');
