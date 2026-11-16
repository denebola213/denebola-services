# Mastodon

Fediverse サーバ（`mstdn.nostalgia-tns.net`）。以前は **Rock 5B（aarch64）の Docker Compose** で
動いていましたが、このリポジトリの **rootless Quadlet** へ移行しました。移行元と同一の
**v4.7.5** で開始しています。

公開は **サービス専用の Cloudflare Tunnel**（既存トンネルをそのまま流用。新規作成なし）で、
ダッシュボードの Public hostname（`mstdn.nostalgia-tns.net` → `https://proxy:443`、実トンネルの ingress を確認済み）も
変更不要です（`mastodon-proxy` が旧 Compose の `proxy` と同じネットワークエイリアスを持つため）。

## 構成

```text
                 Cloudflare Tunnel (mastodon-cloudflared, 既存トンネル流用)
                              |
                              | https://proxy:443
                              v
mastodon.network ── mastodon-proxy (nginx :443 TLS + :4430, loopback 公開)
                    |        |
                    |        +── http://web:3000       (mastodon-web, Puma)
                    |        +── http://streaming:4000 (mastodon-streaming)
                    |
                    +── mastodon-web        (Rails / Puma, 127.0.0.1:3001)
                    +── mastodon-sidekiq    (背景ジョブ)
                    +── mastodon-streaming  (WebSocket,   127.0.0.1:4000)
                    +── mastodon-postgres   (PG17, ~/mastodon/data/postgres, NVMe)
                    +── mastodon-redis      (Redis 7,   ~/mastodon/data/redis, NVMe)
                    +── 添付ファイル        (~ mastodon/data/system, NVMe)
```

| データ | 場所 | 理由 |
| --- | --- | --- |
| PostgreSQL | ホスト NVMe | 低遅延。論理ダンプ/リストアで移行（生コピーは rootless が引き継げない） |
| 添付ファイル（`public/system`） | ホスト NVMe | 移行元 volume（約 54 GB）の tar ストリーム転送。keep-id でホスト所有のまま |
| Redis | ホスト NVMe | キャッシュ扱い。**移行対象外**（下記） |

## 移行しなかったもの（意図的）

| 旧 Compose サービス | 判断 |
| --- | --- |
| pgAdmin（`0.0.0.0:8080` 公開、既定パスワード `password`） | **移行しない**。LAN に無防備に開く構成で、DB 管理は `podman exec mastodon-postgres psql` ですむ |
| Prometheus / Grafana（LAN 公開の監視） | **今回移行しない**。連邦・公開に不要。必要なら別途起票して Quadlet 化する |
| Elasticsearch（コメントアウト済み） | 移行しない。全文検索なしの現状維持 |

## 前提

- Fedora CoreOS。`systemd` の user manager で動く rootless Podman（Quadlet）。
- アプリ3本（web / sidekiq / streaming）のイメージは **uid 991（mastodon）で起動し、su/chown しない**
  ことを実機（`docker inspect` の `User=mastodon`、entrypoint は tini のみ）で確認済み。
  そのため `UserNS=keep-id:uid=991,gid=991` + `User=991:991` でホストユーザー（uid 1000）へ
  マップし、`data/system` の所有者をホスト側に保ちます（SilverBullet と同じ型）。
- `data/system` を web と sidekiq で共有するため、SELinux ラベルは `:z`（共有）です。
  `:Z`（専用）だと2つの MCS カテゴリが競合し、互いのファイルが読めなくなります。
- nginx は **:443 TLS が本命**（既存トンネルの ingress `https://proxy:443` に合わせる）。
  証明書は自己署名（`~/mastodon/data/nginx-certs/`）。接続するのは cloudflared のみで
  `noTLSVerify:true` のため公開 CA は不要。:4430（平文 h2c）はホスト側の loopback 確認用に併置。
  旧スタックの :80 リダイレクトブロックは廃止（Cloudflare Tunnel が唯一の入口）。
  証明書の再生成:
  ```bash
  mkdir -p ~/mastodon/data/nginx-certs
  podman run --rm -v ~/mastodon/data/nginx-certs:/etc/nginx/certs:Z docker.io/library/nginx:1.30-alpine \
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/nginx/certs/proxy.key \
      -out /etc/nginx/certs/proxy.crt -days 825 -subj "/CN=mstdn.nostalgia-tns.net" \
      -addext "subjectAltName=DNS:mstdn.nostalgia-tns.net,DNS:proxy"
  ```

## セットアップ

```bash
# 1) データディレクトリ（すべて rootless ユーザー所有）
mkdir -p ~/mastodon/data/{postgres,redis,system,nginx-log,nginx-certs} ~/mastodon/conf.d

# 2) 環境ファイル（秘密はリポジトリ外。ファイルが無いと起動しません）
cp ~/denebola-services/mastodon/app.env.example        ~/mastodon/app.env
cp ~/denebola-services/mastodon/postgres.env.example   ~/mastodon/postgres.env
cp ~/denebola-services/mastodon/cloudflared.env.example ~/mastodon/cloudflared.env
chmod 600 ~/mastodon/*.env
# 実値を入れる（移行時は rock5b からコピー。README「移行」参照）

# 3) nginx 設定と自己署名証明書（:443 用。上記「前提」のコマンドで生成）
cp ~/denebola-services/mastodon/conf.d/nginx.conf ~/mastodon/conf.d/nginx.conf

# 4) ユニットの symlink（basename がユニット名になる）
for f in ~/denebola-services/mastodon/mastodon.{network,container} \
         ~/denebola-services/mastodon/mastodon-{postgres,redis,web,sidekiq,streaming,proxy,cloudflared}.container; do
  ln -sf "$f" ~/.config/containers/systemd/
done

# 5) 生成物の確認（起動前に必ず）
/usr/lib/systemd/system-generators/podman-system-generator --user --dryrun
systemctl --user daemon-reload
```

## 起動

```bash
systemctl --user start mastodon-postgres.service
# DB が空なら、ここで論理バックアップを流し込む（下の「移行」を参照）
systemctl --user start mastodon-redis.service
systemctl --user start mastodon-web.service mastodon-sidekiq.service mastodon-streaming.service
systemctl --user start mastodon-proxy.service
```

`mastodon-web` は `mastodon-cloudflared` を `Wants=` で一緒に上げます。
ただし**移行直後は cloudflared を起動しないでください**（下記「移行」のカットオーバー順）。

## 確認

```bash
systemctl --user is-enabled mastodon-web.service      # generated
systemctl --user is-active  mastodon-{postgres,redis,web,sidekiq,streaming,proxy}.service
podman ps --filter name=mastodon --format '{{.Names}} | {{.Status}}'
# origin（トンネルを経由しない直接確認。nginx の proxy_cache を避けるためクエリでキャッシュを外す）
curl -s http://127.0.0.1:3001/health
# :4430 is plain h2c; Rails answers 301 to https. Follow it for the body:
curl -sk -L "http://127.0.0.1:4430/api/v2/instance?cb=$RANDOM" -H "Host: mstdn.nostalgia-tns.net" | head -c 200
curl -s http://127.0.0.1:4000/api/v1/streaming/health
podman exec mastodon-postgres pg_isready -U mastodon -d mastodon_production
stat -c '%U:%G %n' ~/mastodon/data/system
```

期待値: `/api/v2/instance` に `"version":"4.7.5"`（移行時点）、全コンテナ Up。

## 移行（rock5b の Docker Compose から）

DB のデータディレクトリを丸ごとコピーしてはいけません。rootless podman は他ホストの
uid 所有を引き継げないため、**論理ダンプ/リストア**で移します（Immich と同じ手順）。

```bash
# 旧ホストで、まず web / sidekiq を止めて書き込みを止める
# （旧 Compose の配置ディレクトリに入る。パスはホスト固有のため省略）
docker compose stop web sidekiq streaming

# DB の論理ダンプ（-Fc は約 1 GB、テキストの pg_dumpall の約 1/4）
docker exec mstdnnostalgia-tnsnet-db-1 pg_dump -Fc -U mastodon mastodon_production > /tmp/mastodon.dump
docker exec -i mstdnnostalgia-tnsnet-db-1 pg_restore -l < /tmp/mastodon.dump | head -5  # TOC が出れば健全
```

```bash
# 新ホスト（FCOS）で、空の postgres を起動してから流し込む
systemctl --user start mastodon-postgres.service
podman exec -i mastodon-postgres pg_restore -U mastodon -d mastodon_production --clean --if-exists < /tmp/mastodon.dump
podman exec mastodon-postgres pg_isready -U mastodon -d mastodon_production
```

添付ファイル（約 54 GB）は tar ストリームで転送します（所有者はホストユーザーに着地し、
keep-id でコンテナ内 uid 991 として見えます）:

```bash
# 旧ホスト側（volume の中身をコンテナ経由で読む。旧ホストのユーザーに
# volume 直接読み権限は無い）
docker exec <compose-project>-web-1 tar -C /mastodon/public/system -cf - . \
  | ssh <new-host> 'tar -C ~/mastodon/data/system -xf -'
```

Redis（`dump.rdb`）は**コピーしません**。キャッシュとして再構築されますが、
**移行時点で Sidekiq に溜まっていたジョブは失われます**。カットオーバー前に
`docker compose stop sidekiq` のタイミングを合わせてキューを可能な限り消化してください。

秘密（`web.env` / `db.env` / `tunnel.env`）は値を画面に出さず、ホスト間パイプで移します:

```bash
# 旧ホスト → 新ホスト（リポジトリには置かない。chmod 600。
# 旧ホスト側のパスはホスト固有のため <old-service-dir> とする）
ssh <old-host> 'cat <old-service-dir>/web.env'    | ssh <new-host> 'cat > ~/mastodon/app.env && chmod 600 ~/mastodon/app.env'
ssh <old-host> 'cat <old-service-dir>/db.env'     | ssh <new-host> 'cat > ~/mastodon/postgres.env && chmod 600 ~/mastodon/postgres.env'
ssh <old-host> 'cat <old-service-dir>/tunnel.env' | ssh <new-host> 'cat > ~/mastodon/cloudflared.env && chmod 600 ~/mastodon/cloudflared.env'
```

`app.env` の `DB_HOST=db` / `REDIS_HOST=redis` はネットワークエイリアスでそのまま解決されるため、
**値を編集する必要はありません**。`DB_PASS` と `POSTGRES_PASSWORD` が元々一致している前提です。

### カットオーバー順（重要）

**既存トンネルは2台のホストで同時に有効にできません。** 同じトークンのコネクタが
2つ登録されると、Cloudflare がリクエストを両 origin に振り分けてしまいます。
そのため順序を厳守します:

1. FCOS 側は cloudflared を **起動しない**（`mastodon-web` の `Wants=` で上がる前に
   `systemctl --user stop mastodon-cloudflared.service` か、開始前に mask する）
2. FCOS 側 origin を loopback で検証（上の「確認」）
3. **rock5b の tunnel を止める**（`docker compose stop tunnel`、またはスタック全体を停止）
4. その直後に FCOS 側 cloudflared を起動（`systemctl --user start mastodon-cloudflared.service`）
5. 公開 URL を検証: `curl -s "https://mstdn.nostalgia-tns.net/api/v2/instance?cb=$RANDOM"`

ダッシュボード側の変更は不要です（origin は `https://proxy:443` のまま）。
旧ホストのデータ（旧 Compose の配置ディレクトリ、volume、backup/）は
削除せず、切り戻し用に保持します。

## バックアップ

- DB: `pg_dump -Fc -U mastodon mastodon_production` を定期取得し、`~/mastodon/backup/` へ。
  復元は `pg_restore -U mastodon -d mastodon_production`。
- 添付ファイル: `~/mastodon/data/system` をそのまま rsync/tar。ホスト所有なので追加作業なし。
- 旧ホストの `backup/`（cron の `pg_dumpall`、約 24 GB）は移行後も切り戻し用に残します。

## アップグレード

1. リポジトリで `mastodon-web` / `mastodon-sidekiq` / `mastodon-streaming` のイメージタグを
   同一バージョンへ揃えて bump する（`mastodon` と `mastodon-streaming` は必ず同版）。
2. push → ホストで `git pull` → `systemctl --user daemon-reload` →
   `systemctl --user restart mastodon-web.service mastodon-sidekiq.service mastodon-streaming.service`。
3. DB マイグレーションがある場合は、再起動前に
   `podman run --rm --env-file ~/mastodon/app.env --network mastodon.network ghcr.io/mastodon/mastodon:<ver> bundle exec rails db:migrate`
   を流す。pending が無ければ何も出力せず exit 0（確認は `rails db:migrate:status`）。
4. 検証は「確認」の5点セット + 公開 URL への curl。

## トラブルシューティング

- **nginx が古いバージョンを返し続ける**: nginx は upstream の IP を起動時に解決します。
  web を再作成したら必ず `systemctl --user restart mastodon-proxy.service`。切り分けは
  `curl -sk -L "http://127.0.0.1:4430/api/v2/instance?cb=$RANDOM"` で origin を直接叩く。
- **`TUNNEL_TOKEN` が空で cloudflared が落ちる**: `~/mastodon/cloudflared.env` が
  ユニットの読むパスに入っているか、値の長さだけ確認する（値は表示しない）。
- **`Permission denied` で添付が読めない**: `podman inspect mastodon-web --format '{{.ProcessLabel}}'` と
  `ls -Zd ~/mastodon/data/system` を突き合わせる。共有ディレクトリは `:z` 前提です。
