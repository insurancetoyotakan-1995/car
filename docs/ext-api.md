# API ดึงข้อมูลคำขอประกันภัย (สำหรับระบบอื่น)

อ่านอย่างเดียว · ระบบปลายทางเป็นฝ่ายเรียกมาดึง · ตอบเป็น JSON

## เรียกอย่างไร

```
POST https://wpbjjiaheoquhigmqynz.supabase.co/rest/v1/rpc/ins_ext_requests
```

| Header | ค่า |
|---|---|
| `apikey` | anon key ของโปรเจกต์ (ค่า `anonKey` ในไฟล์ `config.js`) |
| `X-API-Key` | คีย์ของระบบคุณ — ขอจากผู้ดูแลระบบประกัน |
| `Content-Type` | `application/json` |

Body เป็น JSON ทุกช่องไม่บังคับ ส่ง `{}` ได้

| ช่อง | ความหมาย |
|---|---|
| `p_since`, `p_after` | ตำแหน่งที่ดึงถึงรอบก่อน — ใช้ค่า `next.since` / `next.after` จากคำตอบครั้งล่าสุด · ไม่ส่ง = เริ่มจากใบแรก |
| `p_status` | `new` รอตรวจสอบ · `contacted` ติดต่อแล้ว · `quoted` เสนอราคาแล้ว · `done` ปิดการขาย · `cancelled` ยกเลิก |
| `p_brand` | `toyota` หรือ `hino` |
| `p_limit` | จำนวนใบต่อครั้ง 1–500 (ค่าเริ่มต้น 200) |
| `p_key` | ใช้แทน header `X-API-Key` ได้ ถ้าระบบของคุณตั้ง header เองไม่ได้ |

## ตัวอย่าง

```bash
curl -X POST "https://wpbjjiaheoquhigmqynz.supabase.co/rest/v1/rpc/ins_ext_requests" \
  -H "apikey: $ANON_KEY" \
  -H "X-API-Key: $INS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"p_status":"done","p_limit":100}'
```

## คำตอบ

```json
{
  "ok": true,
  "scope": "full",
  "count": 2,
  "has_more": false,
  "next": { "since": "2026-10-09T03:15:22.481+00:00", "after": "7b0c…" },
  "server_time": "2026-10-09T03:20:00+00:00",
  "data": [ { "no": "INS-2610-004", "status": "done", "…": "…" } ]
}
```

- เรียงตาม `changed_at` (เวลาที่ใบถูกแก้ล่าสุด) จากเก่าไปใหม่
- `has_more: true` = ยังมีใบเหลือ ให้เรียกซ้ำทันทีด้วยค่า `next`

## ดึงแบบต่อเนื่อง (sync)

1. ครั้งแรกส่ง `{}` แล้ววนเรียกด้วย `next` จนกว่า `has_more` เป็น `false`
2. เก็บค่า `next` ล่าสุดไว้
3. รอบถัดไป (เช่น ทุก 5 นาที) ส่ง `next` ที่เก็บไว้เป็น `p_since` / `p_after` — จะได้เฉพาะใบที่ใหม่หรือถูกแก้หลังจากนั้น
4. ใบเดิมที่ถูกแก้จะกลับมาอีกครั้ง — ให้เขียนทับในระบบของคุณโดยใช้ `id` (หรือ `no`) เป็นกุญแจ

## ช่องข้อมูลหลักในแต่ละใบ

| กลุ่ม | ช่อง |
|---|---|
| ใบ | `id`, `no`, `brand`, `kind` (`self` พนักงานทำเอง / `refer` แนะนำลูกค้า), `status`, `status_note`, `created_at`, `changed_at` |
| พนักงาน | `emp_id`, `emp_name`, `emp_dept`, `emp_branch`, `emp_verified` |
| ผู้ทำประกัน | `insured_title`, `insured_name`, `relation` · *(เฉพาะคีย์ full)* `id_card`, `birth_date`, `phone_mobile`, `phone_home`, `addr`, `moo`, `road`, `tambon`, `amphoe`, `province`, `zipcode`, `occupation`, `workplace`, `income` |
| รถ | `car_plate`, `car_province`, `car_vin`, `car_brand`, `car_model`, `car_year`, `covers`, `old_policy_end` |
| เสนอราคา | `quote_insurer`, `quote_type`, `quote_net`, `quote_gross`, `quote_disc`, `quote_act_net`, `quote_act_gross`, `quote_act_disc`, `quote_total`, `quote_start`, `quote_end`, `quote_act_start`, `quote_act_end`, `quote_note`, `quote_at`, `receipt_no` |
| ผู้ดูแล | `assigned_to` (รหัสพนักงาน), `assigned_name` |
| ไฟล์แนบ | `files` — รายชื่อไฟล์ (`name`, `tag`, `mime`, `size`) **ไม่มีลิงก์ดาวน์โหลด** |

วันที่เป็น ค.ศ. รูปแบบ ISO · จำนวนเงินเป็นบาท ทศนิยม 2 ตำแหน่ง · `quote_total` คือยอดที่ต้องชำระหลังหักส่วนลด ปัดขึ้นเป็นบาทเต็ม

## ข้อจำกัด

- 60 ครั้งต่อนาทีต่อคีย์ เกินแล้วได้ error "เรียกถี่เกินไป"
- คีย์ผิดหรือถูกปิด ได้ error "API key ไม่ถูกต้องหรือถูกปิดแล้ว"
- ทุกครั้งที่เรียกถูกบันทึกไว้ (เวลา · IP · จำนวนใบ)
- เก็บคีย์ไว้ฝั่งเซิร์ฟเวอร์เท่านั้น ห้ามใส่ในหน้าเว็บหรือแอปที่ผู้ใช้เปิดดูโค้ดได้
