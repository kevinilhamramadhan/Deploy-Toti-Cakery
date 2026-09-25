#!/usr/bin/env bash
# Pemeriksaan sebelum `docker compose up` di server baru.
#
# Semua yang diperiksa di sini pernah benar-benar menggagalkan deploy, dan
# tidak satu pun terlihat dari `docker compose config` — yang tetap melaporkan
# "valid" untuk stack yang tidak akan pernah jalan. Dua contoh nyata:
#
#   - Folder model/ tertinggal saat menyalin. `config` valid, `up` gagal dengan
#     "bind source path does not exist".
#   - DNS server belum siap saat boot. Gateway WhatsApp gagal membuka
#     web.whatsapp.com, sesinya batal, tapi /ping tetap 200 sehingga
#     `docker ps` menulis "healthy" untuk gateway yang nol pesannya masuk.
#
# Dijalankan dari folder yang sama dengan docker-compose.yaml:
#   ./preflight.sh
#
# Keluar dengan status 1 kalau ada yang GAGAL. PERINGATAN tidak menggagalkan:
# artinya bisa jalan, tapi ada yang perlu kamu ketahui.

set -uo pipefail

GAGAL=0
PERINGATAN=0

hijau() { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
merah() { printf '  \033[31mGAGAL\033[0m %s\n' "$1"; GAGAL=$((GAGAL + 1)); }
kuning() { printf '  \033[33mAWAS\033[0m  %s\n' "$1"; PERINGATAN=$((PERINGATAN + 1)); }
judul() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── 1. Perkakas ───────────────────────────────────────────────────────────────
judul "1. Perkakas"

if command -v docker >/dev/null 2>&1; then
  ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null | tr -d '\n')
  hijau "docker ${ver:-(klien ada, daemon belum terjawab)}"
else
  merah "docker tidak ditemukan"
fi

if docker compose version >/dev/null 2>&1; then
  hijau "docker compose $(docker compose version --short 2>/dev/null)"
else
  merah "plugin 'docker compose' tidak ada (compose v1 'docker-compose' tidak dipakai di sini)"
fi

if ! docker info >/dev/null 2>&1; then
  merah "daemon docker tidak bisa dihubungi — jalankan dengan sudo, atau tambahkan user ke grup docker"
fi

# ── 2. Berkas yang harus ada ─────────────────────────────────────────────────
judul "2. Berkas"

[ -f docker-compose.yaml ] && hijau "docker-compose.yaml" || merah "docker-compose.yaml tidak ada"

if [ -f .env ]; then
  hijau ".env ada"
  izin=$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env 2>/dev/null)
  case "$izin" in
    600 | 400) hijau ".env izinnya $izin" ;;
    *) kuning ".env izinnya $izin — berisi kata sandi dan token; sebaiknya: chmod 600 .env" ;;
  esac
else
  merah ".env tidak ada — salin dulu: cp .env.server .env && chmod 600 .env"
fi

# model/ dirujuk sebagai `configs.file`, yang TIDAK diperiksa oleh `config`.
for berkas in model/ollama-entrypoint.sh model/Modelfile.qwen3-1.7b-v5 \
  model/Modelfile.qwen3-1.7b-v6 model/Modelfile.qwen3-1.7b-v6b; do
  [ -f "$berkas" ] && hijau "$berkas" || merah "$berkas tidak ada (folder model/ tertinggal saat menyalin?)"
done

# ── 3. Nilai wajib di .env ───────────────────────────────────────────────────
judul "3. Nilai wajib di .env"

WAJIB=(
  TUNNEL_ID TUNNEL_CREDENTIALS_JSON PUBLIC_HOSTNAME
  POSTGRES_PASSWORD SECRET_KEY SERVICE_API_KEY INTERNAL_API_KEY
  WEBHOOK_TOKEN WWEBJS_API_KEY CHATBOT_WA_NUMBER WUD_ADMIN_PASSWORD
)
if [ -f .env ]; then
  for nama in "${WAJIB[@]}"; do
    nilai=$(grep -E "^${nama}=" .env | head -1 | cut -d= -f2-)
    if [ -z "$nilai" ]; then
      merah "$nama kosong atau tidak ada"
    elif printf '%s' "$nilai" | grep -qiE '^(ganti|isi|xxx|todo|<|placeholder)'; then
      merah "$nama masih berisi nilai contoh: ${nilai:0:20}…"
    else
      hijau "$nama terisi"
    fi
  done
fi

# ── 4. Sumber daya ───────────────────────────────────────────────────────────
judul "4. Sumber daya"

# Chatbot menjalankan LLM 1,7 B di CPU plus Chromium untuk gateway WhatsApp.
if [ -r /proc/meminfo ]; then
  ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  if [ "$ram_mb" -ge 7000 ]; then
    hijau "RAM ${ram_mb} MB"
  elif [ "$ram_mb" -ge 5000 ]; then
    kuning "RAM ${ram_mb} MB — cukup, tapi mepet. Ollama + Chromium mudah kena OOM di bawah 8 GB"
  else
    merah "RAM ${ram_mb} MB — di bawah 5 GB stack ini tidak akan stabil"
  fi
fi

disk_gb=$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "${disk_gb:-}" ]; then
  # image ±4 GB + bobot model ±1,7 GB + basis data + volume
  if [ "$disk_gb" -ge 15 ]; then
    hijau "disk kosong ${disk_gb} GB"
  elif [ "$disk_gb" -ge 10 ]; then
    kuning "disk kosong ${disk_gb} GB — image dan bobot model butuh ±8 GB"
  else
    merah "disk kosong ${disk_gb} GB — tidak cukup untuk image dan bobot model"
  fi
fi

arch=$(uname -m)
case "$arch" in
  x86_64 | amd64) hijau "arsitektur $arch" ;;
  *) kuning "arsitektur $arch — image aplikasinya dibangun untuk amd64; periksa ketersediaan arm64 sebelum lanjut" ;;
esac

# ── 5. Jaringan ──────────────────────────────────────────────────────────────
judul "5. Jaringan"

# DNS host: yang ini menentukan apakah `docker pull` bisa jalan.
if getent hosts ghcr.io >/dev/null 2>&1; then
  hijau "DNS host bisa resolve ghcr.io"
else
  merah "DNS host TIDAK bisa resolve ghcr.io — semua pull image akan gagal"
fi

# Jebakan yang benar-benar terjadi: resolver IPv6 yang tidak bisa dihubungi,
# sehingga docker pull gagal dengan 'cannot assign requested address'.
if [ -r /etc/resolv.conf ]; then
  ns_v6=$(grep -E '^nameserver\s+[0-9a-fA-F]*:' /etc/resolv.conf | awk '{print $2}')
  ns_v4=$(grep -E '^nameserver\s+[0-9]+\.' /etc/resolv.conf | awk '{print $2}')
  if [ -n "$ns_v6" ] && [ -z "$ns_v4" ]; then
    kuning "resolv.conf hanya berisi nameserver IPv6 ($ns_v6) — kalau host tidak punya rute IPv6, docker pull gagal. Tambahkan nameserver IPv4."
  fi
  if grep -qE '^nameserver\s+\S+\s+\S+' /etc/resolv.conf; then
    kuning "ada baris 'nameserver' dengan lebih dari satu alamat — hanya alamat pertama yang dipakai; pisahkan jadi beberapa baris"
  fi
fi

# DNS dari dalam container: inilah yang dipakai gateway WhatsApp dan ollama.
if docker info >/dev/null 2>&1; then
  if docker run --rm --network bridge busybox:1.36 nslookup web.whatsapp.com >/dev/null 2>&1; then
    hijau "DNS container bisa resolve web.whatsapp.com"
  else
    merah "DNS container TIDAK bisa resolve web.whatsapp.com — sesi WhatsApp tidak akan pernah tersambung"
  fi
fi

# Host yang benar-benar dihubungi stack ini. Tanpa salah satunya, ada bagian
# yang gagal diam-diam, bukan berhenti dengan pesan jelas.
for host in ghcr.io huggingface.co web.whatsapp.com api.cloudflare.com; do
  if curl -fsS --max-time 12 -o /dev/null "https://$host" 2>/dev/null ||
    curl -fsS --max-time 12 -o /dev/null -I "https://$host" 2>/dev/null; then
    hijau "bisa menghubungi $host"
  else
    kuning "tidak bisa menghubungi https://$host — periksa firewall atau proxy keluar"
  fi
done

# ── 6. Kesimpulan ────────────────────────────────────────────────────────────
judul "Kesimpulan"
if [ "$GAGAL" -gt 0 ]; then
  printf '  %d GAGAL, %d peringatan. Perbaiki yang GAGAL sebelum menjalankan `docker compose up -d`.\n\n' "$GAGAL" "$PERINGATAN"
  exit 1
fi
if [ "$PERINGATAN" -gt 0 ]; then
  printf '  Lolos dengan %d peringatan. Boleh lanjut `docker compose up -d`.\n\n' "$PERINGATAN"
  exit 0
fi
printf '  Semua lolos. Lanjutkan dengan `docker compose up -d`.\n\n'
