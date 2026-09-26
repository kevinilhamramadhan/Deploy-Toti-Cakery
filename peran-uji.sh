#!/usr/bin/env bash
# Mengganti peran satu nomor WhatsApp antara Owner dan pembeli biasa, untuk
# menguji tool Owner (laporan keuangan, analitik) dari HP sendiri.
#
#   ./peran-uji.sh 081234567890 owner     # jadikan Owner
#   ./peran-uji.sh 081234567890 pembeli   # kembali jadi pembeli biasa
#   ./peran-uji.sh 081234567890           # lihat peran sekarang
#
# Cara kerjanya: chatbot menganggap sebuah nomor Owner kalau ada user staf
# ber-role Owner yang AKTIF dengan nomor itu (GET /users/owner-numbers). Skrip
# ini memelihara satu user khusus bernama "uji-owner-<4 digit akhir>" dan cuma
# menyalakan/mematikan is_active-nya. Kata sandinya acak dan tidak pernah
# ditampilkan: user ini bukan untuk login Admin Site, dan tidak menerima
# alihan chat (handles_takeover=false).
#
# Chatbot menyimpan daftar peran selama 5 menit, jadi perubahan baru terasa
# paling lambat 5 menit kemudian.
#
# Owner tetap bisa memesan seperti pelanggan biasa; bedanya hanya dapat dua
# tool tambahan, dan "paling laris?" dijawab dengan analitik penjualan, bukan
# rekomendasi menu.

set -euo pipefail

nomor=$(printf '%s' "${1:-}" | tr -cd '0-9')
case "$nomor" in
  0*) nomor="62${nomor#0}" ;;
esac
if ! [[ "$nomor" =~ ^62[0-9]{8,13}$ ]]; then
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
mode=${2:-status}
nama="uji-owner-${nomor: -4}"
# Kolom phone_number diisi apa adanya dari Admin Site ("0857…", "+62 857…"),
# jadi pembandingnya dinormalkan dulu ke bentuk 62… di SQL.
sama_nomor="regexp_replace(regexp_replace(u.phone_number, '[^0-9]', '', 'g'), '^0', '62') = '$nomor'"

psql_() {
  docker compose exec -T postgres sh -c \
    'psql -U "${POSTGRES_USER:-toti}" -d "${POSTGRES_DB:-toti}" -v ON_ERROR_STOP=1 -At "$@"' -- "$@"
}

status() {
  local baris
  baris=$(psql_ -c "SELECT u.username, r.nama_role, u.is_active FROM users u
                    JOIN roles r ON r.id = u.role_id
                    WHERE $sama_nomor ORDER BY u.id")
  if [ -z "$baris" ]; then
    echo "$nomor: pembeli biasa (tidak ada user staf dengan nomor ini)"
  else
    echo "$nomor: user staf dengan nomor ini —"
    printf '%s\n' "$baris" | awk -F'|' '{printf "  %-22s %-6s %s\n", $1, $2, ($3=="t" ? "aktif" : "nonaktif")}'
  fi
}

case "$mode" in
  status)
    status
    ;;
  owner)
    lain=$(psql_ -c "SELECT username FROM users u WHERE $sama_nomor AND username <> '$nama'")
    if [ -n "$lain" ]; then
      echo "Nomor ini sudah dipakai user staf lain ($lain). Ubah perannya lewat Admin Site." >&2
      exit 1
    fi
    ada=$(psql_ -c "SELECT count(*) FROM users WHERE username = '$nama'")
    if [ "$ada" = "0" ]; then
      hash=$(docker compose exec -T backend python -c \
        "import secrets; from app.core.security import hash_password; print(hash_password(secrets.token_urlsafe(32)))")
      psql_ -c "INSERT INTO users (username, password_hash, role_id, is_active, phone_number,
                                   email, handles_takeover, created_at)
                VALUES ('$nama', '$hash', 1, true, '$nomor', '$nama@toticakery.local', false, now())" >/dev/null
    else
      psql_ -c "UPDATE users SET is_active = true, role_id = 1 WHERE username = '$nama'" >/dev/null
    fi
    status
    echo "Berlaku di chatbot paling lambat 5 menit lagi."
    ;;
  pembeli)
    psql_ -c "UPDATE users SET is_active = false WHERE username = '$nama'" >/dev/null
    status
    echo "Berlaku di chatbot paling lambat 5 menit lagi."
    ;;
  *)
    echo "Mode tidak dikenal: $mode (pakai owner, pembeli, atau kosongkan)" >&2
    exit 2
    ;;
esac
