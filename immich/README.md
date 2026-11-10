# Immich

写真・動画ライブラリ（PhotoPrism から移行済み）。**原本は NAS（OMV の btrfs）に置き、
DB とサムネイルだけをホストの NVMe に載せる**構成です。以前は PVE の VM 101 で Docker
Compose により動いていましたが、このリポジトリの rootless Quadlet へ移しました。

## 構成

```text
                 Cloudflare Tunnel (immich-cloudflared)
                              |
                              | http://immich_server:2283
                              v
immich.network ── immich-server (rootless, :2283)
                    |            |
                    |            +── /data/thumbs          → %h/immich/data/thumbs        (NVMe)
                    |            +── /data/encoded-video   → %h/immich/data/encoded-video (NVMe)
                    |            +── /data                  → /mnt/immich-images (NFS, 原本)
                    |
                    +── immich-postgres (pg14 + VectorChord, %h/immich/data/postgres, NVMe)
                    +── immich-valkey   (job queue)
                    +── immich-ml       (CPU 推論, %h/immich/data/ml-cache)
```

| データ | 場所 | 理由 |
| --- | --- | --- |
| 原本（`upload/`, `library/` 等） | OMV の btrfs（RAID1）× NFS | 容量。2.5GbE で実効 200MB/s 前後 |
| PostgreSQL | ホスト NVMe | NFS 上の DB は遅延と可用性の両面で不利 |
| thumbs / encoded-video | ホスト NVMe | ランダム I/O が主。失っても再生成できる |
| model cache | ホスト NVMe | 再ダウンロードを避ける |

## 前提

- Fedora CoreOS。`systemd` の user manager で動く rootless Podman（Quadlet）。
- NFS のマウントだけは root が必要なので、`mnt-immich-images.mount` は
  `/etc/systemd/system/` に置く。他のユニットは `~/.config/containers/systemd/` に symlink。
- NFS の export は `192.168.20.103:/immich-images`。マウントオプションの
  `context="system_u:object_r:container_file_t:s0"` が無いと rootless Podman は
  `Permission denied` になる（NFS は `:z`/`:Z` でラベルできない）。
- NFS 側のディレクトリ所有者は **ホストユーザー（uid 1000）** であること。
  Docker 時代は root(0) 所有だったため、移行時に一度だけ chown している。

## セットアップ

```bash
# 1) データディレクトリ（すべて rootless ユーザー所有）
mkdir -p ~/immich/data/{postgres,thumbs,encoded-video,ml-cache}

# 2) NFS マウント（root）
sudo cp ~/denebola-services/immich/mnt-immich-images.mount /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now mnt-immich-images.mount
findmnt /mnt/immich-images

# 3) 環境ファイル（秘密はリポジトリ外）
cp ~/denebola-services/immich/immich.env.example ~/immich/immich.env
cp ~/denebola-services/immich/cloudflared.env.example ~/immich/cloudflared.env
chmod 600 ~/immich/immich.env ~/immich/cloudflared.env
# DB_PASSWORD / POSTGRES_PASSWORD / TUNNEL_TOKEN を実値に置き換える

# 4) ユニットの symlink（basename がユニット名になる）
for f in ~/denebola-services/immich/immich.{network,container} \
         ~/denebola-services/immich/immich-{postgres,valkey,ml,server,cloudflared}.container; do
  ln -sf "$f" ~/.config/containers/systemd/
done

# 5) 生成物の確認（起動前に必ず）
/usr/lib/systemd/system-generators/podman-system-generator --user --dryrun
systemctl --user daemon-reload
```

## 起動

```bash
systemctl --user start immich-postgres.service
# DB が空なら、ここで論理バックアップを流し込む（下の「移行」を参照）
systemctl --user start immich-server.service
```

`immich-server` は `immich-postgres` / `immich-valkey` / `immich-ml` と NFS マウントに
依存し、`immich-cloudflared` は `Wants=` で一緒に上がる。

## 確認

```bash
systemctl --user is-enabled immich-server.service      # generated
systemctl --user is-active  immich-{postgres,valkey,ml,server}.service
podman ps --filter name=immich --format '{{.Names}} | {{.Status}}'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2283/   # 200
curl -s http://127.0.0.1:2283/api/server/version                   # {"major":3,...}
podman exec immich-postgres pg_isready -U postgres
stat -c '%U:%G %n' ~/immich/data/postgres
```

## 移行（VM 101 の Docker Compose から）

DB のデータディレクトリを丸ごとコピーしてはいけない。rootless podman は uid 999 の
ディレクトリを引き継げないため、**論理ダンプ/リストア**で移す。

```bash
# 旧ホスト（移行元）で、immich を止めてから
docker compose stop immich-server immich-machine-learning
docker compose exec -T database pg_dumpall -U postgres --globals-only > globals.sql
docker compose exec -T database pg_dump    -U postgres -d postgres -Fc   > immich.dump

# 新ホスト（FCOS）で、空の postgres を起動してから流し込む
systemctl --user start immich-postgres.service
podman exec -i immich-postgres psql       -U postgres -d postgres -f - < globals.sql
podman exec -i immich-postgres pg_restore -U postgres -d postgres --clean --if-exists < immich.dump
systemctl --user start immich-server.service
```

サムネイルとエンコード済み動画は NFS から NVMe へ `rsync` で複製する（immich を止めてから
差分だけ流すと停止時間が短い）。

```bash
rsync -a /mnt/immich-images/thumbs/        ~/immich/data/thumbs/
rsync -a /mnt/immich-images/encoded-video/ ~/immich/data/encoded-video/
```

## バックアップ

- DB: `pg_dump -Fc` を定期取得（`/var/lib/containers` とは別ディスクへ）。
- 原本: NAS 側のスナップショット（OMV の btrfs snapshot）に依存する。
- `thumbs` / `encoded-video` / `ml-cache` は**バックアップ対象外**。消えても再生成できる。

## アップグレード

`immich-server` と `immich-ml` は同じタグで揃える。

```bash
cd ~/denebola-services && git pull
# immich/immich-{server,ml}.container の Image= を新しいタグに編集して push → ホストで pull
systemctl --user daemon-reload
systemctl --user restart immich-server.service
```

**ダウングレード不可**（immich のマイグレーションは一方通行）。上げる前に必ず DB ダンプを取る。

## トラブルシューティング

| 症状 | 原因と対処 |
| --- | --- |
| `Unit mnt-immich-images.mount not found` | system の `.mount` を user ユニットの `Requires=` に書けない。`ExecStartPre` で `mountpoint -q` を検査する形にしている |
| `statfs /etc/localtime: no such file or directory`（podman exit 125） | rootless で `/etc/localtime` を bind できない（user namespace 内で zoneinfo の symlink が解決しない）。`TZ=` だけ使う |
| `chown: changing ownership of '/var/lib/postgresql/data': Permission denied` | `:U` は chown だけで SELinux ラベルは変えない。`:U,Z` にする |
| `Permission denied` で `/data` が読めない | NFS マウントに `context=container_file_t` が無い、または NFS 側の所有者が uid 1000 でない |
| postgres が `could not access directory` で落ちる | `:U` が効くのはユーザー所有のディレクトリだけ。空でない/所有者違いのディレクトリを置くと再現する。論理ダンプで入れ直す |
| 起動しても DB が空 | `immich-postgres` の initdb が先に走る。ダンプは initdb 完了後（`pg_isready` が通ってから）流す |
| トンネルは繋がるがアプリに届かない | Cloudflare 側の Service URL が `http://immich_server:2283` か確認。`immich-server` の `NetworkAlias=` で旧名を維持している |
| 起動直後に再起動ループ | `systemctl --user show immich-server -p NRestarts` と `journalctl --user -u immich-server -n 50` を見る。過去の失敗行が残るので、稼働判定は Up 時間で行う |
