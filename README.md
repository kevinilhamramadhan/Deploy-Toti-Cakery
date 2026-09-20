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

## Kalau servernya komputer desktop

Stack ini juga jalan di PC biasa, misalnya komputer lab, tapi desktop punya dua
kebiasaan yang tidak dimiliki VPS dan keduanya mematikan situs tanpa pesan apa
pun:

```bash
sudo systemctl enable --now docker      # tanpa ini, stack tidak hidup lagi setelah listrik mati
sudo usermod -aG docker $USER           # logout-login setelah ini
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

Baris ketiga yang paling sering terlewat. Begitu mesinnya suspend, cloudflared
ikut mati dan `PUBLIC_HOSTNAME` berhenti menjawab, padahal `restart:
unless-stopped` tidak menolong: containernya tidak crash, mesinnya yang tidur.

Sebelum meninggalkan mesinnya, `sudo reboot` sekali lalu pastikan
`docker compose ps` kembali sehat dan situsnya terbuka. Menguji ini selagi
masih bisa menyentuh komputernya jauh lebih murah daripada menemukannya rusak
dari jarak jauh.

## Akses jarak jauh

Komputer lab atau kantor umumnya ada di balik NAT, tanpa IP publik dan tanpa
port forward. Tailscale menyelesaikannya tanpa membuka apa pun ke internet,
sama seperti alasan stack ini memakai cloudflared:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --hostname=lab-toti
sudo tailscale set --auto-update
```

Opsi `--ssh` membuat autentikasi SSH memakai identitas tailnet, jadi tidak ada
kunci yang perlu disalin atau dirotasi. Dari laptop cukup `ssh user@lab-toti`.

Dua hal wajib diselesaikan **selagi masih di depan mesinnya**, karena keduanya
tidak bisa diperbaiki dari jauh:

| Langkah | Kalau dilewatkan |
|---|---|
| Admin console → Machines → mesin ini → **Disable key expiry** | kunci kedaluwarsa dalam 180 hari; mesinnya hilang dari tailnet dan hanya bisa dipulihkan dengan datang lagi |
| `tailscale status` dari laptop, diuji di tempat | kalau jaringan memblok UDP, koneksinya jatuh ke relay DERP — tetap jalan, tapi lambat, dan lebih baik ketahuan sekarang |

## Pembaruan otomatis

CI di ketiga repo kode sudah mendorong image ke GHCR pada setiap push ke `main`,
lengkap dengan tag `:latest` dan `:sha-<commit>`. Yang dikerjakan repo ini
adalah paruh keduanya: menariknya turun. Service `watchtower` di compose
memeriksa GHCR tiap lima menit dan merekreasi container yang image-nya berubah.

Tidak ada langkah tambahan. Watchtower ikut naik pada `docker compose up -d`
biasa, tidak lewat overlay, justru supaya tidak bisa terlewat: overlay membuat
setiap `up` polos berikutnya diam-diam membuang labelnya dan CD berhenti tanpa
error.

Yang diperbarui **hanya chatbot-service**, karena hanya itu yang berlabel
`com.centurylinklabs.watchtower.enable=true` dan watchtower dijalankan dengan
`--label-enable`. Ini disengaja: `backend` dan `frontend` berasal dari repo
milik orang lain, dan tanpa batasan tersebut setiap merge mereka langsung
mendarat di produksi tanpa sepengetahuan siapa pun di sini. Keduanya diperbarui
dengan sadar:

```bash
docker compose pull backend frontend && docker compose up -d
```

Untuk rollback, sematkan tag tetap di `.env` lalu `up -d`. Selama `CHATBOT_IMAGE`
tidak menunjuk `:latest`, watchtower tidak punya yang bisa diperbarui:

```bash
CHATBOT_IMAGE=ghcr.io/kevinilhamramadhan/chatbot-cakery:sha-<commit>
```

Kalau paket GHCR-nya private, watchtower butuh kredensial: `docker login
ghcr.io` dengan PAT ber-scope `read:packages`, lalu tambahkan berkas hasilnya
sebagai volume pada service `watchtower`, yaitu
`${HOME}/.docker/config.json:/config.json:ro`.

## Pindah ke server lain

Domainnya **tidak perlu diubah sama sekali**. Cloudflare mengarahkan
`PUBLIC_HOSTNAME` ke `<TUNNEL_ID>.cfargotunnel.com`, dan yang menentukan
mesin mana yang menjawab adalah siapa yang sedang menjalankan tunnel dengan
kredensial itu — bukan alamat IP. Jadi tidak ada DNS record yang disentuh,
tidak ada propagasi yang ditunggu.

Konsekuensinya satu, dan ini penting: **matikan server lama dulu.** Cloudflare
mengizinkan satu tunnel dijalankan dari beberapa mesin sekaligus sebagai
replika, dan kalau dua server sama-sama hidup, permintaan pelanggan dibagi acak
ke dua stack dengan basis data yang berbeda. Gejalanya membingungkan: pesanan
kadang ada, kadang hilang.

### 1. Berkas

`.env` dipakai apa adanya — tidak ada satu pun nilai di dalamnya yang terikat
pada mesin tertentu. `TUNNEL_ID` dan `TUNNEL_CREDENTIALS_JSON` milik tunnel,
bukan milik server.

```bash
# di server baru
git clone https://github.com/kevinilhamramadhan/Deploy-Toti-Cakery.git ~/toticakery
scp ~/toticakery/.env user@server-baru:~/toticakery/.env   # dari server lama
ssh user@server-baru 'chmod 600 ~/toticakery/.env'
```

### 2. Data

Sebagian volume berisi data yang tidak bisa dibuat ulang, sebagian lagi hanya
unduhan yang akan terisi sendiri.

| Volume | Isi | Perlu dipindah? |
|---|---|---|
| `db_data` | Seluruh basis data: pesanan, pelanggan, produk, stok | **Ya** (±64 MB) |
| `wwebjs_sessions` | Kredensial WhatsApp | **Ya** (±94 MB) — kalau tidak, harus scan QR ulang |
| `chatbot_data` | State percakapan, keranjang, pesanan tertunda | **Ya** (±140 KB) |
| `be_static` | Gambar produk yang diunggah | **Ya** (±8 KB) |
| `chroma_data` | Vektor FAQ | Tidak — dibuat ulang otomatis oleh `chatbot-ingest` |
| `ollama_models` | Bobot model | Tidak — ditarik ulang dari Hugging Face (±3,7 GB) |
| `cloudflared_conf` | Konfigurasi tunnel | Tidak — dibuat ulang dari `.env` |

Di server **lama**, hentikan stack lebih dulu agar basis datanya tidak disalin
dalam keadaan setengah tertulis:

```bash
cd ~/toticakery && docker compose down
mkdir -p ~/pindahan && cd ~/pindahan
for v in db_data wwebjs_sessions chatbot_data be_static; do
  docker run --rm -v toticakery_$v:/data:ro -v ~/pindahan:/keluar busybox:1.36 \
    tar czf /keluar/$v.tgz -C /data .
done
ls -lh ~/pindahan
```

Salin ke server baru, lalu pulihkan **sebelum** `up` pertama:

```bash
scp ~/pindahan/*.tgz user@server-baru:~/pindahan/

# di server baru
cd ~/toticakery
for v in db_data wwebjs_sessions chatbot_data be_static; do
  docker volume create toticakery_$v
  docker run --rm -v toticakery_$v:/data -v ~/pindahan:/masuk busybox:1.36 \
    tar xzf /masuk/$v.tgz -C /data
done
```

Nama volumenya berawalan `toticakery_` karena `name: toticakery` di baris
pertama compose. Kalau salah prefiks, compose akan membuat volume kosong baru
dan stack-nya hidup tanpa data — tanpa error apa pun.

### 3. Jalankan

```bash
cd ~/toticakery
./preflight.sh          # wajib: server baru, jaringan baru
docker compose up -d
docker compose logs -f ollama      # unduhan model, 10-15 menit
```

### 4. Periksa

```bash
# sesi WhatsApp ikut pindah?
docker compose exec chatbot-service python -c \
  "import asyncio; from app.whatsapp_client.client import whatsapp_client; \
   print(asyncio.run(whatsapp_client.session_state()))"
```

Hasilnya harus `CONNECTED`. Kalau `session_not_found`, tunggu satu siklus
(30 detik) — chatbot menyalakannya sendiri. Kalau setelah beberapa menit tetap
tidak tersambung, kredensialnya tidak terbawa dan perlu scan QR ulang mengikuti
bagian **Menautkan WhatsApp** di atas.

Terakhir, buka `https://PUBLIC_HOSTNAME` di browser. Kalau halamannya terbuka
dan menunya terisi, seluruh rantainya — tunnel, frontend, backend, basis data —
sudah pindah.

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
