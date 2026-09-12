/* =====================================================================
   ตั้งค่าเชื่อม Supabase — แก้ 2 ค่านี้ให้เป็นของโปรเจกต์คุณ แล้วเสร็จ

   หาค่าได้ที่: Supabase Dashboard → Project Settings → API
     url      = "Project URL"
     anonKey  = "Project API keys" → anon / public

   🔒 anon key ปลอดภัยที่จะอยู่ในไฟล์นี้ (ออกแบบมาให้ฝังในหน้าเว็บ)
      ตัวที่คุมว่าทำอะไรได้จริงคือ RLS + RPC ใน supabase/schema.sql
   ⚠️⚠️ ห้ามเอา "service_role" key มาใส่ที่นี่เด็ดขาด
      ตัวนั้นข้าม RLS ได้ทุกอย่าง = ใครเปิดหน้าเว็บก็ลบ/อ่านข้อมูลลูกค้าได้ทั้งฐาน
   ===================================================================== */
window.SUPA = {
  url:     'https://YOUR-PROJECT-REF.supabase.co',
  anonKey: 'YOUR-ANON-KEY',
};
