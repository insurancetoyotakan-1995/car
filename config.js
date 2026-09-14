/* =====================================================================
   ตั้งค่าเชื่อม Supabase — แก้ 2 ค่านี้ให้เป็นของโปรเจกต์คุณ แล้วเสร็จ

   หาค่าได้ที่: Supabase Dashboard → Project Settings → API
     url      = "https://wpbjjiaheoquhigmqynz.supabase.co"
     anonKey  = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndwYmpqaWFoZW9xdWhpZ21xeW56Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkxOTkxNjQsImV4cCI6MjEwNDc3NTE2NH0.7V9mXlHJN8NYzOuytqzmgXIH2th1rc7w-dvBabAvEN4" → anon / public

   🔒 anon key ปลอดภัยที่จะอยู่ในไฟล์นี้ (ออกแบบมาให้ฝังในหน้าเว็บ)
      ตัวที่คุมว่าทำอะไรได้จริงคือ RLS + RPC ใน supabase/schema.sql
   ⚠️⚠️ ห้ามเอา "service_role" key มาใส่ที่นี่เด็ดขาด
      ตัวนั้นข้าม RLS ได้ทุกอย่าง = ใครเปิดหน้าเว็บก็ลบ/อ่านข้อมูลลูกค้าได้ทั้งฐาน
   ===================================================================== */
window.SUPA = {
  url:     'https://wpbjjiaheoquhigmqynz.supabase.co',
  anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndwYmpqaWFoZW9xdWhpZ21xeW56Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkxOTkxNjQsImV4cCI6MjEwNDc3NTE2NH0.7V9mXlHJN8NYzOuytqzmgXIH2th1rc7w-dvBabAvEN4',
  // ลิงก์แอดเพื่อน LINE OA "แจ้งเตือนทำประกันภัย" (แยกจาก OA ใบสำคัญจ่าย) — ใช้ทำ QR ในหน้าผูก LINE
  // หาได้ที่ LINE Official Account Manager → เพิ่มเพื่อน · รูปแบบ https://line.me/R/ti/p/@xxxxxxx
  // ว่าง = หน้าผูก LINE ขึ้นข้อความให้ขอลิงก์จากผู้ดูแลแทน QR
  lineAddUrl: '',
};
