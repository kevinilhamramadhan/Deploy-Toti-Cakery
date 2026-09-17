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
| `preflight.sh` | Pemeriksaan server dan jaringan sebelum `up` |
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
./preflight.sh            # periksa server dan jaringannya dulu
docker compose up -d
```

### Mengapa `preflight.sh` ada

`docker compose config` melaporkan "valid" untuk stack yang tidak akan pernah
jalan. Ia tidak membaca isi `.env`, tidak memeriksa folder `model/`, dan tidak
tahu apa-apa soal jaringan server. Semua yang diperiksa `preflight.sh` pernah
benar-benar menggagalkan deploy:

| Yang diperiksa | Gejalanya kalau dilewatkan |
|---|---|
| Folder `model/` lengkap | `up` gagal: `bind source path does not exist` |
| 10 nilai wajib di `.env` terisi | container berhenti saat start, pesannya terkubur di log |
| DNS host bisa resolve `ghcr.io` | semua pull image gagal |
| DNS container bisa resolve `web.whatsapp.com` | sesi WhatsApp tidak pernah tersambung |
| `resolv.conf` punya nameserver IPv4 | `docker pull` gagal: `cannot assign requested address` |
| RAM dan disk | Ollama kena OOM, atau bobot model gagal diunduh |
| Bisa menghubungi GHCR, Hugging Face, WhatsApp, Cloudflare | satu bagian mati diam-diam |

Keluar dengan status 1 kalau ada yang **GAGAL**; **AWAS** tidak menggagalkan.

### Kalau `docker pull` gagal padahal internet jalan

Penyebab yang paling sering: `/etc/resolv.conf` hanya berisi nameserver IPv6
sementara server tidak punya rute IPv6, atau satu baris `nameserver` diisi dua
alamat sekaligus — hanya alamat pertama yang dipakai. `preflight.sh` menandai
keduanya. Kalau resolver hostnya memang tidak bisa diperbaiki, daemon Docker
bisa diberi resolver sendiri:

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{ "dns": ["1.1.1.1", "8.8.8.8"] }
EOF
sudo systemctl restart docker
```

Ini menyetel DNS untuk daemon dan container, tanpa menyentuh resolver host.

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

### Sesi yang mati akan pulih sendiri

Penautan di atas hanya perlu dilakukan **sekali**. Kredensialnya disimpan di
volume `wwebjs_sessions` dan dipakai lagi setiap container start.

Yang dulu menjadi masalah: gateway menginisialisasi sesinya sekali saja saat
start. Kalau saat itu jaringan belum siap — persis yang terjadi setiap server
baru boot — Puppeteer gagal membuka `web.whatsapp.com`, sesinya batal, dan
tidak pernah dicoba lagi walau jaringannya hidup beberapa detik kemudian.
Gateway tetap menjawab `/ping` dengan 200, sehingga `docker ps` menulis
`healthy` untuk gateway yang nol pesannya masuk.

Sekarang chatbot memeriksa state sesi pada setiap siklus latar belakang dan
menyalakannya lagi kalau mati, dengan jeda dua menit agar inisialisasi yang
sedang berjalan tidak dibatalkan. Tidak ada lagi `docker compose restart
wwebjs-api` manual setelah reboot.

Healthcheck gateway juga tidak lagi hanya memanggil `/ping`, melainkan
memeriksa state sesinya, sehingga `docker ps` menyatakan `unhealthy` ketika
sesinya memang mati.

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
