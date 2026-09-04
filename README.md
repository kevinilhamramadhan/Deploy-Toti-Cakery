# Toti Cakery — stack deploy

Repo ini hanya berisi **skrip deploy**, bukan kode. Kode ketiga komponen ada di
reponya masing-masing; compose menarik image jadi dari GitHub Container
Registry, dan bobot model chatbot ditarik dari Hugging Face.

Isinya sengaja cuma dua berkas:

| Berkas | Isi |
|---|---|
| `docker-compose.yml` | Seluruh stack, 9 service. Entrypoint ollama dan Modelfile tertanam di dalamnya sebagai `configs`, jadi tidak ada berkas pendukung yang perlu ikut disalin. |
| `.env.server` | Template konfigurasi. Salin jadi `.env` di server, isi nilainya. |

## Menjalankan di server

```bash
cp .env.server .env && chmod 600 .env
nano .env                 # isi 9 nilai wajib, lihat komentar di dalamnya
docker compose up -d
```

Tidak ada langkah manual lain sebelum `up`. Yang berjalan otomatis:

- image backend, frontend, dan chatbot ditarik dari GHCR;
- **ollama** menarik model dari Hugging Face (~1,1 GB) lalu membangunnya dari
  Modelfile yang tertanam di compose, dan menarik model embedding;
- **chatbot-ingest** mengisi ChromaDB dari berkas FAQ di dalam image;
- **cloudflared** membuka tunnel keluar ke Cloudflare — tidak ada port yang
  dibuka di mesin ini, dan tidak butuh IP publik maupun port forward.

`up` pertama 10–15 menit karena unduhan model; berikutnya beberapa detik.
Pantau: `docker compose logs -f ollama`

## Satu langkah manual, sesudah `up`

Tautkan WhatsApp dengan memindai QR (butuh HP, jadi tidak bisa diotomatiskan):

```bash
curl -H "x-api-key: $WWEBJS_API_KEY" http://localhost:3000/session/start/toti
curl -H "x-api-key: $WWEBJS_API_KEY" http://localhost:3000/session/qr/toti/image -o qr.png
```

## Catatan

`.env` **tidak** ikut di-commit — isinya password database, `SECRET_KEY`, token
webhook, dan kredensial tunnel. `.gitignore` di repo ini memakai pola whitelist:
semua diabaikan kecuali yang disebut eksplisit, supaya berkas rahasia yang baru
muncul tidak pernah ikut ter-commit tanpa sengaja.

Katalog produk dan FAQ tidak ikut di image database — isi lewat Admin Site
setelah stack hidup, kalau tidak menu chatbot akan kosong.
