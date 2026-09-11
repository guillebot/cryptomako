#!/usr/bin/env bash
set -euo pipefail

NAME="${CRYPTOMAKO_MINIO_NAME:-cryptomako-minio}"
ROOT_USER="${CRYPTOMAKO_MINIO_USER:-cryptomako}"
ROOT_PASS="${CRYPTOMAKO_MINIO_PASS:-cryptomako-minio-dev}"
BUCKET="${CRYPTOMAKO_MINIO_BUCKET:-cryptomako-poc}"
API_PORT="${CRYPTOMAKO_MINIO_API_PORT:-9000}"
CONSOLE_PORT="${CRYPTOMAKO_MINIO_CONSOLE_PORT:-9001}"

if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null
fi

docker run -d --name "$NAME" \
  -p "${API_PORT}:9000" \
  -p "${CONSOLE_PORT}:9001" \
  -e "MINIO_ROOT_USER=${ROOT_USER}" \
  -e "MINIO_ROOT_PASSWORD=${ROOT_PASS}" \
  minio/minio server /data --console-address ":9001"

echo "waiting for MinIO on :${API_PORT}..."
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${API_PORT}/minio/health/live" >/dev/null; then
    break
  fi
  sleep 1
done

docker run --rm --network host \
  -e "MC_HOST_local=http://${ROOT_USER}:${ROOT_PASS}@127.0.0.1:${API_PORT}" \
  minio/mc mb -p "local/${BUCKET}" >/dev/null

cat <<EOF
MinIO is up.
  API      http://127.0.0.1:${API_PORT}
  Console  http://127.0.0.1:${CONSOLE_PORT}
  User     ${ROOT_USER}
  Bucket   ${BUCKET}

Copy a Cryptomator vault into ${BUCKET}/family/ then:

  export CRYPTOMAKO_SECRET_KEY=${ROOT_PASS}
  export CRYPTOMAKO_PASSWORD='your-vault-password'
  swift run cryptomako unlock --endpoint http://127.0.0.1:${API_PORT} --bucket ${BUCKET} --prefix family/ --access-key ${ROOT_USER}
EOF
