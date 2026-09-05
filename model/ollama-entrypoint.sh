#!/bin/sh
# Entrypoint ollama: menyiapkan model SENDIRI saat container start, supaya
# `docker compose up -d` cukup satu perintah dan tidak ada langkah manual.
#
# Urutan sumber bobot model:
#   1. file .gguf lokal di /modelfiles -> dipakai kalau ada (VPS tanpa internet,
#      atau saat menguji GGUF baru sebelum diunggah ke Hugging Face)
#   2. Hugging Face                   -> ditarik langsung oleh ollama, tanpa
#      token, karena repo modelnya publik
#
# Nama model yang dibuat SELALU $LLM_MODEL, dan template-nya SELALU diambil dari
# Modelfile di repo -- bukan dari metadata GGUF. Itu yang menjamin model hasil
# tarikan HF berperilaku identik dengan yang diuji di laptop.
set -eu

ollama serve &
SERVER_PID=$!
until ollama list >/dev/null 2>&1; do sleep 1; done

LLM=${LLM_MODEL:-toti-qwen-1.7b-v5}
EMB=${EMBEDDING_MODEL:-qwen3-embedding:0.6b}
HF_REF=${LLM_HF_REF:-hf.co/LasagnaS/toti-qwen-1.7b-v5-gguf:Q4_K_M}
VER=${LLM##*-}                                   # toti-qwen-1.7b-v5 -> v5
MODELFILE=/modelfiles/Modelfile.qwen3-1.7b-$VER

have() {
  ollama list | awk 'NR>1 { sub(/:latest$/, "", $1); print $1 }' | grep -qx "${1%:latest}"
}

if ! have "$EMB"; then
  echo "[init] menarik model embedding: $EMB"
  ollama pull "$EMB"
fi

if have "$LLM"; then
  echo "[init] $LLM sudah ada, dilewati"
elif [ ! -f "$MODELFILE" ]; then
  echo "[init] !! Modelfile tidak ada: $MODELFILE" >&2
  echo "[init]    Diturunkan dari LLM_MODEL=$LLM. Samakan penamaannya." >&2
else
  # Nama GGUF dibaca dari baris FROM Modelfile supaya keduanya tidak pernah
  # lepas sinkron saat versi model naik.
  GGUF=$(awk 'tolower($1)=="from"{print $2; exit}' "$MODELFILE" | sed 's#.*/##')
  if [ -f "/modelfiles/$GGUF" ]; then
    echo "[init] membangun $LLM dari berkas lokal /modelfiles/$GGUF"
    sed "s#^[Ff][Rr][Oo][Mm] .*#FROM /modelfiles/$GGUF#" "$MODELFILE" > /tmp/Modelfile
  else
    echo "[init] berkas lokal tidak ada — menarik dari Hugging Face: $HF_REF"
    echo "[init] (sekali saja, ~1,1 GB; tersimpan di volume ollama_models)"
    ollama pull "$HF_REF"
    # FROM diarahkan ke model hasil tarikan, TEMPLATE & PARAMETER tetap dari
    # Modelfile repo.
    sed "s#^[Ff][Rr][Oo][Mm] .*#FROM $HF_REF#" "$MODELFILE" > /tmp/Modelfile
  fi
  ollama create "$LLM" -f /tmp/Modelfile
  echo "[init] $LLM siap"
fi

wait "$SERVER_PID"
