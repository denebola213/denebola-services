#!/usr/bin/env bash
#
# Back up the hermes-home volume and ~/workspace to an OMV NAS over SFTP.
# Connection settings come from hermes-backup.env (EnvironmentFile), see
# backup.env.example. Run by hermes-backup.timer (daily at 04:00).
#
set -euo pipefail

: "${BACKUP_SFTP_HOST:?BACKUP_SFTP_HOST is required}"
: "${BACKUP_SFTP_USER:?BACKUP_SFTP_USER is required}"
: "${BACKUP_SFTP_PATH:?BACKUP_SFTP_PATH is required}"
: "${BACKUP_SSH_KEY:?BACKUP_SSH_KEY is required}"

BACKUP_SFTP_PORT="${BACKUP_SFTP_PORT:-22}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"

# 展開: %h と先頭の ~ をホームディレクトリに
BACKUP_SSH_KEY="${BACKUP_SSH_KEY/#%h/$HOME}"
BACKUP_SSH_KEY="${BACKUP_SSH_KEY/#\~/$HOME}"

TARGET="${BACKUP_SFTP_USER}@${BACKUP_SFTP_HOST}"
REMOTE="${BACKUP_SFTP_PATH}"
SSH_OPTS=(-p "$BACKUP_SFTP_PORT" -i "$BACKUP_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-P "$BACKUP_SFTP_PORT" -i "$BACKUP_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -q)

STAMP="$(date +%F)"
WORK="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK"
  # 失敗してもコンテナ群を必ず戻す（webui の起動で agent も連鎖起動）
  systemctl --user start hermes-webui.service || true
}
trap cleanup EXIT

echo "==> stopping hermes services for a consistent snapshot"
systemctl --user stop hermes-webui.service hermes-agent.service

echo "==> archiving volume hermes-home"
podman volume export hermes-home | gzip -6 > "$WORK/hermes-home-${STAMP}.tar.gz"

if [ -d "$HOME/workspace" ]; then
  echo "==> archiving ~/workspace"
  tar -C "$HOME" -czf "$WORK/workspace-${STAMP}.tar.gz" workspace
fi

echo "==> verifying archives"
gzip -t "$WORK"/*.tar.gz

echo "==> preparing remote directory"
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p '$REMOTE'"

echo "==> uploading"
for f in "$WORK"/*.tar.gz; do
  base="$(basename "$f")"
  # .tmp へ送ってから rename（途中失敗で半端なファイルを残さない）
  scp "${SCP_OPTS[@]}" "$f" "$TARGET:$REMOTE/$base.tmp"
  ssh "${SSH_OPTS[@]}" "$TARGET" "mv -f '$REMOTE/$base.tmp' '$REMOTE/$base'"
done

echo "==> pruning remote archives older than ${BACKUP_KEEP_DAYS} days"
ssh "${SSH_OPTS[@]}" "$TARGET" \
  "find '$REMOTE' -maxdepth 1 -name '*.tar.gz' -mtime +${BACKUP_KEEP_DAYS} -delete"

echo "==> done: $STAMP"
