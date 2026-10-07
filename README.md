# stop — MicroCTS Scalper

ربات اسکالپر M1 طلا با سورس کامل، ساخته‌شده از ترکیب:
- **MicroMap** (محمدعلی پورصمدی) — تریگر ورود: اسپایک → میکروکانال → شکست، با قانون طلایی «۳ استاپ = ابطال ستاپ»
- **CTS** (هومن مقراضی) — فیلتر زمینه: روند تایم بالا → PRZ → مومنتوم → تریگر
- **موتور ضد مارجین** — از کالبدشکافی لاگ‌های `Javier Gold Scalper V2` (۱۸ پوزیشن هم‌زمان، ۲۸ استاپ‌اوت، ۹٬۵۷۲ خطای No-Money)

## راهنمای کامل (فارسی)
- **[docs/README.fa.md](docs/README.fa.md)** — نصب، کامپایل، پریست‌ها، برنامه آزمون
- **[docs/strategy-research.md](docs/strategy-research.md)** — قوانین MicroMap و CTS از منابع رسمی + آمار خرابی‌های Javier
- `EA/MicroCTS_Scalper.mq5` — سورس ربات
- `EA/presets/*.set` — پریست‌های SAFE و AGGRESSIVE
- `analysis/audit_javier_deals.py` — بازتولید آمار forensic روی CSV معاملات

## هشدار
ابتدا Strategy Tester (تیک واقعی، ≥۳ ماه)، سپس دمو ≥۲ هفته. هیچ سودی تضمین نیست.
