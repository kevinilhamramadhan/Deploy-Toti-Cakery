# Toti Cakery: stack deploy

Repositori ini hanya berisi **skrip deploy**, bukan kode aplikasi. Kode ketiga
komponen berada di repositori masing-masing. Compose menarik image yang sudah
jadi dari GitHub Container Registry, sedangkan bobot model chatbot ditarik dari
Hugging Face.

Isi repositori:

| Berkas | Keterangan |
|---|---|
| `docker-compose.yaml` | Seluruh stack, terdiri atas 9 service |
| `.env.server` | Template konfigurasi. Salin menjadi `.env` di server, lalu isi nilainya |
| `model/ollama-entrypoint.sh` | Skrip yang menyiapkan model AI ketika container dijalankan |
| `model/Modelfile.qwen3-1.7b-v5` | Resep model: bobot, template percakapan, dan parameter |

Ketiganya, yaitu compose, `.env`, dan folder `model/`, **harus tersedia di
server**.

## Menjalankan di server

Cara paling ringkas adalah langsung dari repositori ini:

```bash
git clone https://github.com/kevinilhamramadhan/Deploy-Toti-Cakery.git ~/toticakery
cd ~/toticakery
cp .env.server .env && chmod 600 .env
nano .env                 # isi 10 nilai wajib, lihat komentar di dalamnya
docker compose up -d
```

Jika server tidak memiliki akses git, salin berkasnya secara manual dari
laptop. Opsi `-r` wajib disertakan karena `model/` merupakan folder:

```bash
scp -r docker-compose.yaml .env.server model/ user@server:~/toticakery/
```

Setelah menyalin, pastikan foldernya ikut terbawa:

```bash
ls model/     # harus berisi dua berkas
```

Pemeriksaan ini bukan kehati-hatian yang berlebihan. Jika folder `model/`
tertinggal, `docker compose config` **tetap melaporkan konfigurasi valid**. Yang
gagal adalah perintah `up`, dengan pesan `bind source path does not exist`.

Tidak ada langkah manual lain sebelum `up`. Proses berikut berjalan otomatis:

- image backend, frontend, dan chatbot ditarik dari GHCR;
- **ollama** menarik model dari Hugging Face, berukuran sekitar 1,1 GB, lalu
  membangunnya dari `model/Modelfile.qwen3-1.7b-v5`, kemudian menarik model
  embedding berukuran sekitar 600 MB;
- **chatbot-ingest** mengisi ChromaDB dari berkas FAQ yang tertanam di dalam
  image;
- **cloudflared** membuka tunnel keluar menuju Cloudflare. Karena itu, tidak ada
  port yang perlu dibuka di mesin ini, dan stack ini tidak membutuhkan IP publik
  maupun port forward.

Perintah `up` yang pertama memerlukan waktu 10 sampai 15 menit karena harus
mengunduh model. Perintah berikutnya hanya memerlukan beberapa detik. Prosesnya
dapat dipantau dengan `docker compose logs -f ollama`.

## Menautkan WhatsApp

Langkah ini merupakan satu-satunya langkah manual setelah `up`. Prosesnya
membutuhkan ponsel, sehingga tidak dapat diotomatiskan.

Kode QR tidak akan muncul pada `docker compose up -d`. Sesi bernama `toti` baru
dibuat setelah diminta secara eksplisit, dan kode QR-nya disajikan melalui API,
bukan dicetak ke log.

Port 3000 juga **tidak dipublikasikan** ke host, karena satu-satunya jalan masuk
ke stack ini adalah cloudflared. Akibatnya, `curl localhost:3000` tidak akan
menjawab. Panggilan harus dilakukan dari container sekali pakai yang ikut
bergabung ke network compose:

```bash
cd ~/toticakery && set -a && . ./.env && set +a

# 1. memulai sesi
docker run --rm --network toticakery_default curlimages/curl -s \
  -H "x-api-key: $WWEBJS_API_KEY" http://wwebjs-api:3000/session/start/toti

# 2. mengambil kode QR. Siapkan ponsel terlebih dahulu, karena kode QR
#    kedaluwarsa dalam waktu sekitar satu menit
docker run --rm --network toticakery_default curlimages/curl -s \
  -H "x-api-key: $WWEBJS_API_KEY" \
  http://wwebjs-api:3000/session/qr/toti/image > qr.png
```

Pindai kode QR tersebut melalui menu WhatsApp, yaitu Perangkat tertaut, lalu
Tautkan perangkat. Jika kode QR telanjur kedaluwarsa, ulangi perintah kedua
saja. Sesinya sudah berjalan, sehingga yang diperlukan hanya kode QR yang baru.

Hasil unduhan ditulis melalui redirect, bukan melalui opsi `-v`, karena image
curl berjalan sebagai uid 100 dan sering gagal menulis ke folder milik pengguna
lain.

Sesi yang berhasil ditautkan dapat diverifikasi dengan perintah berikut:

```bash
docker run --rm --network toticakery_default curlimages/curl -s \
  -H "x-api-key: $WWEBJS_API_KEY" http://wwebjs-api:3000/session/status/toti
```

Hasilnya harus `CONNECTED`, bukan `session_not_found`.

## Catatan

Berkas `.env` **tidak** ikut disimpan ke repositori karena memuat kata sandi
basis data, `SECRET_KEY`, token webhook, dan kredensial tunnel. Berkas
`.gitignore` di repositori ini memakai pola whitelist, yaitu semua berkas
diabaikan kecuali yang disebutkan secara eksplisit. Dengan begitu, berkas
rahasia yang baru muncul tidak akan pernah ikut ter-commit tanpa sengaja.

Backend menyemai basis data secara mandiri ketika dijalankan, yaitu bila tabel
`roles` masih kosong. Data yang dibuat meliputi role, tiga akun contoh, produk,
resep, dan FAQ. Kata sandi ketiga akun tersebut bersifat tetap dan tertulis di
repositori backend. Karena situs ini dapat diakses dari internet, **gantilah
ketiga kata sandi tersebut melalui Admin Site segera setelah login pertama**.

Foto produk disimpan di Cloudinary, bukan di server. Ketiga nilai
`CLOUDINARY_*` di `.env` harus diisi agar Admin Site dapat mengunggah foto.
Bila dikosongkan, seluruh stack tetap berjalan, hanya unggah foto yang ditolak.
Karena `image_url` yang tersimpan berupa URL absolut, chatbot meneruskannya apa
adanya ketika mengirim foto ke pelanggan.

URL notifikasi yang didaftarkan di dashboard Midtrans harus memakai prefiks
`/api`, yaitu `https://toticakery.web.id/api/payments/notify`. Hanya jalur
tersebut yang diteruskan nginx ke backend. Tanpa `/api`, callback dari Midtrans
akan mendarat di SPA fallback dan status pembayaran tidak akan pernah
diperbarui.
