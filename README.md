# Toti Cakery — stack deploy

Repo ini hanya berisi **skrip deploy**, bukan kode. Kode ketiga komponen ada di
reponya masing-masing; compose menarik image jadi dari GitHub Container
Registry, dan bobot model chatbot ditarik dari Hugging Face.

Isinya:

| Berkas | Isi |
|---|---|
| `docker-compose.yml` | Seluruh stack, 9 service |
| `.env.server` | Template konfigurasi. Salin jadi `.env` di server, isi nilainya |
| `model/ollama-entrypoint.sh` | Skrip yang menyiapkan model AI saat container start |
| `model/Modelfile.qwen3-1.7b-v5` | Resep model: bobot, template percakapan, parameter |

Ketiganya (compose, `.env`, dan folder `model/`) **harus ada di server**.

## Menjalankan di server

Cara paling ringkas, langsung dari repo ini:

```bash
git clone https://github.com/kevinilhamramadhan/Deploy-Toti-Cakery.git ~/toti
cd ~/toti
cp .env.server .env && chmod 600 .env
nano .env                 # isi 9 nilai wajib, lihat komentar di dalamnya
docker compose up -d
```

Server tanpa akses git? salin manual dari laptop — `-r` wajib karena `model/`
adalah folder:

```bash
scp -r docker-compose.yml .env.server model/ user@server:~/toti/
```

Setelah menyalin, pastikan foldernya ikut terbawa:

```bash
ls model/     # harus ada dua berkas
```

Ini bukan kehati-hatian berlebihan: bila `model/` tertinggal,
`docker compose config` **tetap melaporkan valid**, dan yang gagal adalah `up`
dengan pesan `bind source path does not exist`.

Tidak ada langkah manual lain sebelum `up`. Yang berjalan otomatis:

- image backend, frontend, dan chatbot ditarik dari GHCR;
- **ollama** menarik model dari Hugging Face (~1,1 GB) lalu membangunnya dari
  `model/Modelfile.qwen3-1.7b-v5`, dan menarik model embedding (~600 MB);
- **chatbot-ingest** mengisi ChromaDB dari berkas FAQ di dalam image;
- **cloudflared** membuka tunnel keluar ke Cloudflare — tidak ada port yang
  dibuka di mesin ini, dan tidak butuh IP publik maupun port forward.

`up` pertama 10–15 menit karena unduhan model; berikutnya beberapa detik.
Pantau: `docker compose logs -f ollama`

## Menautkan WhatsApp — satu langkah manual sesudah `up`

Butuh HP, jadi tidak bisa diotomatiskan. QR tidak pernah muncul di `up -d`:
sesi `toti` baru dibuat setelah diminta, dan QR-nya disajikan lewat API, bukan
dicetak ke log.

Port 3000 **tidak dipublish** ke host — satu-satunya jalan masuk ke stack ini
adalah cloudflared. Jadi `curl localhost:3000` tidak akan menjawab; panggil
dari container sekali-pakai yang ikut network compose:

```bash
cd ~/toticakery && set -a && . ./.env && set +a

# 1. mulai sesinya
docker run --rm --network toticakery_default curlimages/curl -s \
  -H "x-api-key: $WWEBJS_API_KEY" http://wwebjs-api:3000/session/start/toti

# 2. ambil QR-nya -- siapkan HP dulu, QR kedaluwarsa sekitar semenit
docker run --rm --network toticakery_default curlimages/curl -s \
  -H "x-api-key: $WWEBJS_API_KEY" \
  http://wwebjs-api:3000/session/qr/toti/image > qr.png
```

Scan dari WhatsApp → Perangkat tertaut → Tautkan perangkat. Telat? ulangi
perintah kedua saja; sesinya sudah jalan, yang perlu cuma QR baru.

Hasilnya ditulis lewat redirect, bukan `-v`: image curl berjalan sebagai uid
100 dan sering gagal menulis ke folder milik pengguna lain.

Verifikasi:

```bash
docker run --rm --network toticakery_default curlimages/curl -s \
  -H "x-api-key: $WWEBJS_API_KEY" http://wwebjs-api:3000/session/status/toti
```

Harus `CONNECTED`, bukan `session_not_found`.

## Catatan

`.env` **tidak** ikut di-commit — isinya password database, `SECRET_KEY`, token
webhook, dan kredensial tunnel. `.gitignore` di repo ini memakai pola whitelist:
semua diabaikan kecuali yang disebut eksplisit, supaya berkas rahasia yang baru
muncul tidak pernah ikut ter-commit tanpa sengaja.

Backend menyemai database sendiri saat start bila tabel `roles` masih kosong:
role, tiga akun contoh, produk, resep, dan FAQ. Password akun seed itu tetap
dan tertulis di repo backend — **ganti ketiganya lewat Admin Site begitu login
pertama**, karena situs ini terbuka di internet.

URL notifikasi yang didaftarkan di dashboard Midtrans harus memakai prefiks
`/api`, yaitu `https://toticakery.web.id/api/payments/notify`. Hanya jalur
itu yang diproxy nginx ke backend; tanpa `/api` callback-nya mendarat di SPA
fallback dan status pembayaran tidak pernah diperbarui.
