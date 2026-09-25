#!/usr/bin/env bash
# Mengosongkan sesi dan riwayat percakapan chatbot untuk SATU nomor WhatsApp,
# supaya nomor itu bisa dipakai uji langsung atau demo seolah pelanggan baru.
#
#   ./reset-percakapan.sh 6281234567890        # minta konfirmasi dulu
#   ./reset-percakapan.sh 081234567890 -y      # tanpa konfirmasi
#
# Yang dihapus, semuanya di SQLite chatbot (volume chatbot_data):
#   sessions               -> state, keranjang, bahasa, data pelanggan, takeover
#   chatbot_conversations  -> riwayat pesan masuk/keluar (konteks LLM)
#   pending_orders         -> pelacak pembayaran & kabar "pesanan siap"
#
# Pesanan yang masih menunggu bayar dibatalkan dulu di backend. Tanpa itu,
# pesanannya menggantung "pending" selamanya, karena yang biasanya membatalkan
# saat kedaluwarsa adalah baris pending_orders yang ikut dihapus di sini.
#
# Yang TIDAK disentuh: pesanan & akun pembeli di backend (Postgres). Pesanan
# lunas tetap tercatat di Admin Site.
#
# Dijalankan dari folder yang sama dengan docker-compose.yaml, dan tidak perlu
# restart: sesi baru dibuat otomatis saat nomor itu mengirim pesan berikutnya.

set -euo pipefail

# Semua argumen selain -y dianggap bagian nomor, jadi "+62 812 3456 7890"
# tanpa tanda kutip pun terbaca utuh.
yakin=
mentah=
for a in "$@"; do
  if [ "$a" = "-y" ]; then yakin=1; else mentah="$mentah$a"; fi
done
[ -n "$mentah" ] || { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

nomor=$(printf '%s' "$mentah" | tr -cd '0-9')
case "$nomor" in
  0*) nomor="62${nomor#0}" ;;
esac
if ! [[ "$nomor" =~ ^62[0-9]{8,13}$ ]]; then
  echo "Nomor tidak dikenali: '$mentah'. Pakai format 62812... atau 0812..." >&2
  exit 2
fi
alamat="${nomor}@c.us"

jalankan() {
  docker compose exec -T -w /app -e PYTHONPATH=/app chatbot-service \
    python - "$alamat" "$1" <<'PY'
import asyncio, sqlite3, sys

alamat, mode = sys.argv[1], sys.argv[2]
db = sqlite3.connect("/app/data/toti_chatbot.db")
tabel = ("sessions", "chatbot_conversations", "pending_orders")

if mode == "lihat":
    for t in tabel:
        n = db.execute(f"SELECT count(*) FROM {t} WHERE wa_number = ?", (alamat,)).fetchone()[0]
        print(f"  {t:<22} {n} baris")
    for ref, status in db.execute(
        "SELECT order_ref, status FROM pending_orders WHERE wa_number = ?", (alamat,)
    ):
        print(f"    pesanan {ref}: {status}")
    sys.exit(0)

from app.backend_client import api as backend

async def batalkan():
    for (ref,) in db.execute(
        "SELECT order_ref FROM pending_orders WHERE wa_number = ? AND status = 'pending'",
        (alamat,),
    ).fetchall():
        try:
            await backend.cancel_order(ref)
            print(f"  pesanan {ref} dibatalkan di backend")
        except Exception as e:
            print(f"  GAGAL membatalkan pesanan {ref} di backend ({str(e).splitlines()[0]}); "
                  "batalkan manual lewat Admin Site")

asyncio.run(batalkan())
with db:
    for t in tabel:
        n = db.execute(f"DELETE FROM {t} WHERE wa_number = ?", (alamat,)).rowcount
        print(f"  {t:<22} {n} baris dihapus")
PY
}

echo "Data chatbot untuk $alamat:"
jalankan lihat

if [ -z "$yakin" ]; then
  read -rp "Hapus semuanya? [y/N] " jawab
  [ "$jawab" = "y" ] || [ "$jawab" = "Y" ] || { echo "Batal."; exit 1; }
fi

jalankan hapus
echo "Selesai. Pesan berikutnya dari nomor ini dimulai sebagai percakapan baru."
