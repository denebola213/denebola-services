# Hermes Agent + WebUI を Cloudflare Tunnel で公開（Podman Quadlet / rootless）

`nousresearch/hermes-agent`（gateway）と `nesquena/hermes-webui`（チャット UI）を
Podman Quadlet で常駐させ、`cloudflare/cloudflared` コンテナから
Cloudflare Tunnel 経由で外部公開する構成です。

インバウンドポートを開けずに、WebUI を HTTPS の公開ホスト名で利用できます。

```text
                        ┌────────────────────┐
  Internet ── HTTPS ───▶│ Cloudflare Edge    │
                        │ (Access / ZeroTrust)│
                        └─────────┬──────────┘
                                  │ Tunnel (outbound のみ)
                        ┌─────────▼──────────┐
                        │ cloudflared        │  hermes.network
                        └──┬────────┬────────┘
      http://hermes-webui:8787 │  │ http://hermes-agent:9119  (dashboard)
      http://hermes-agent:8642 │  │ (gateway API, 任意)
                           │   │
                        ┌──▼───▼───────────┐
                        │ hermes-webui     │
                        │ :8787            │
                        └───┬──────────┬───┘
              hermes-home   │          │  hermes-agent-src (ro)
                        ┌───▼──────────▼───┐
                        │ hermes-agent     │
                        │ :8642 gateway API│
                        │ :9119 dashboard  │
                        └──────────────────┘
```

- ネットワーク: `hermes`（Podman カスタムネットワーク、名前解決に使用）
- ボリューム: `hermes-home`（config/sessions/skills/memory）、`hermes-agent-src`（エージェントのソース）
- ポート公開はすべて `127.0.0.1` のみ。外部到達は cloudflared 経由だけ。
- WebUI 用（`hermes-webui:8787`）に加え、管理用 Web Dashboard
  （`hermes-agent:9119`）と CLI/API 用の OpenAI 互換 API
  （`hermes-agent:8642`）も任意でトンネルへ追加できます（第 6 章）。

---

## 1. Cloudflare Tunnel 方式の比較

| | トークン方式（remotely-managed） | ローカル `config.yml` 方式 |
|---|---|---|
| トンネル作成 | Zero Trust ダッシュボード | `cloudflared tunnel create`（CLI） |
| 認証情報 | ダッシュボードが発行する `TUNNEL_TOKEN` のみ | credentials JSON ファイル |
| ingress（ルーティング） | ダッシュボードで設定 | ホスト上の `config.yml` |
| ホストに必要なファイル | `cloudflared.env` 1 つ | `config.yml` + credentials JSON |
| DNS ルート | ダッシュボードで自動 | `cloudflared tunnel route dns` を 1 回実行 |
| 設定のコード管理 | 不可（Cloudflare 側） | 可（git 管理しやすい） |
| 向いているケース | 手軽に公開したい / 設定をダッシュボードで変更したい | IaC・再現性・オフライン管理を重視 |

このリポジトリの既定は **トークン方式**（`cloudflared.container`）。
ローカル方式へ切り替えたい場合は「5. ローカル config.yml 方式に切り替える」を参照。

---

## 2. 前提

- Podman 4.4 以降（`podman-system-generator` 同梱）。Fedora CoreOS は標準。
- rootless ユーザーで lingering を有効化（FCOS なら `core`）。
- Cloudflare アカウントと、トンネルを割り当てるドメイン。

```bash
sudo loginctl enable-linger "$USER"
```

---

## 3. セットアップ

### 3.1 ファイルを配置

Quadlet ファイルは `~/.config/containers/systemd/`、環境ファイルは `~/hermes/` に置きます。
ユニットはリポジトリへ**シンボリックリンク**、環境ファイルは**コピー**で配置します。

Quadlet ユニットを symlink にしておくと、以後は `git pull` と `daemon-reload` だけで
リポジトリ側の変更を反映できます（第 7 章）。一方、環境ファイルは秘密情報
（`TUNNEL_TOKEN` / `API_SERVER_KEY` / パスワード）とホスト固有の UID/GID を含むため
実ファイルとしてコピーし、`.example` に増えた変数は手動で追記します。

```bash
# このリポジトリのクローン先（どこでも可）。以下は repo 直下で実行する例。
REPO="$(pwd)"

mkdir -p ~/.config/containers/systemd ~/.config/systemd/user ~/hermes ~/workspace

# Quadlet ユニット: リポジトリの実ファイルへ symlink（必ず絶対パスで貼る）
ln -sf "$REPO"/hermes/*.network "$REPO"/hermes/*.volume "$REPO"/hermes/*.container \
    ~/.config/containers/systemd/

# バックアップ用 systemd ユニット（Quadlet ではない通常の user ユニット）: symlink
ln -sf "$REPO"/hermes/hermes-backup.service "$REPO"/hermes/hermes-backup.timer \
    ~/.config/systemd/user/
ln -sf "$REPO"/hermes/hermes-backup.sh ~/hermes/hermes-backup.sh

# 環境ファイル: コピー
cp hermes/hermes.env.example      ~/hermes/hermes.env
cp hermes/cloudflared.env.example ~/hermes/cloudflared.env
cp hermes/backup.env.example      ~/hermes/backup.env
chmod 600 ~/hermes/hermes.env ~/hermes/cloudflared.env ~/hermes/backup.env
```

- symlink は絶対パスで作成します。壊れた相対 symlink は Quadlet generator が
  読み飛ばすため、`cp` で上書きせず symlink のまま維持してください。
- `git pull` でユニットを更新したら、`systemctl --user daemon-reload` を実行して
  生成ユニットを再作成します（generator は `daemon-reload` 時にのみ走ります）。
- バックアップの詳細と接続情報は第 8 章を参照。

### 3.2 環境ファイルを編集

`~/hermes/hermes.env`:

```bash
id -u   # WANTED_UID に入れる (hermes-webui 用)
id -g   # WANTED_GID に入れる (hermes-webui 用)
```

- `WANTED_UID` / `WANTED_GID` は **ホスト UID/GID** に設定（WebUI の実行ユーザー）。
- `HERMES_UID` / `HERMES_GID` は **`10000` 固定**（agent イメージ内の `hermes`
  ユーザーの UID/GID）。`hermes-agent.container` は `UserNS=keep-id:uid=10000,gid=10000`
  でホスト UID を 10000 にマップするため、ここをホスト UID にしてはいけません。
  ホスト UID を入れるとコンテナ内にホストユーザーが同 UID で注入され、
  `usermod: UID already exists` で agent の起動フックが失敗し、crash loop →
  依存する webui / cloudflared も連鎖再起動します。
- `API_SERVER_KEY` と `HERMES_WEBUI_GATEWAY_API_KEY` を **同じ長いランダム文字列**（16 文字以上）に。
  1 回だけ生成して両方へ同じ値を貼り付けます:

  ```bash
  KEY="$(openssl rand -hex 32)"
  sed -i "s|^API_SERVER_KEY=.*|API_SERVER_KEY=${KEY}|; \
          s|^HERMES_WEBUI_GATEWAY_API_KEY=.*|HERMES_WEBUI_GATEWAY_API_KEY=${KEY}|" \
    ~/hermes/hermes.env
  ```

  生成例（どちらでも可）:

  ```bash
  openssl rand -hex 32                          # 64 桁の 16 進数（環境ファイルに安全）
  python3 -c 'import secrets; print(secrets.token_urlsafe(48))'
  ```

  `openssl rand -base64 48` は `+` `/` `=` を含むため、シェル変数や URL に渡す用途では
  上記の hex / `token_urlsafe` が無難です。漏洩すると任意コマンド実行につながるため 256bit 相当を推奨。
- `HERMES_WEBUI_PASSWORD` を設定（外部公開では必須）。
- `HERMES_WEBUI_ALLOWED_ORIGINS` に公開ホスト名（例 `https://hermes.example.com`）。
- `HERMES_DASHBOARD_OIDC_ISSUER` / `HERMES_DASHBOARD_OIDC_CLIENT_ID` /
  `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` に Cloudflare Access の SaaS アプリ
  (OIDC) の値を設定（第 10 章参照）。agent コンテナは
  `HERMES_DASHBOARD=1` / `HERMES_DASHBOARD_HOST=0.0.0.0` で Web Dashboard を
  有効化するため、**非 loopback bind の認証ゲート**が必ず有効になります。
  OIDC 3 値が未設定だとダッシュボードは fail-closed で起動しないので必須です。
  basic 認証は使わず、Cloudflare Access を認証の入口にします。
- `HERMES_DASHBOARD_PUBLIC_URL` にダッシュボードの公開 URL（例
  `https://dashboard.example.com`）。OAuth の redirect URI と、DNS リバインディング
  対策の Host / Origin 完全一致に使われます。Redirect URL は
  `<HERMES_DASHBOARD_PUBLIC_URL>/auth/callback` です。

`~/hermes/cloudflared.env`:

- `TUNNEL_TOKEN` に Cloudflare のトンネルトークンを設定。

### 3.3 Cloudflare 側

1. Zero Trust ダッシュボード → **Networks > Tunnels > Create a tunnel**（Cloudflared）。
2. 表示されるトークンを `~/hermes/cloudflared.env` の `TUNNEL_TOKEN` に貼り付け。
3. トンネルの **Public Hostname** を追加:
   - WebUI: `hermes.example.com` → Service `HTTP` → URL `hermes-webui:8787`
   - Web Dashboard（管理用・任意）: `dashboard.example.com` → Service `HTTP` → URL `hermes-agent:9119`
   - Agent API（CLI/API 用・任意）: `agent.example.com` → Service `HTTP` → URL `hermes-agent:8642`
     （cloudflared は `hermes` ネットワーク上にいるため、コンテナ名で名前解決できます）
4. 必要なら **Access** ポリシーでメール OTP 等を追加（WebUI パスワードと二重防御）。
   Dashboard は 3.3 の Access（前段）+ Hermes 側の OIDC で保護、Agent API を
   公開する場合は Access での保護を強く推奨（第 6 章）。
5. トークンを入手したら保存し、環境ファイルに反映。

### 3.4 起動

```bash
systemctl --user daemon-reload

# 生成されるユニットを事前確認
/usr/lib/systemd/system-generators/podman-system-generator --user --dryrun

systemctl --user start hermes-webui.service   # 依存から agent / cloudflared も起動
```

`[Install] WantedBy=default.target` があるため、`enable` は不要（生成ユニットは
自動起動対象になります）。

---

## 4. 確認

```bash
systemctl --user status hermes-agent.service hermes-webui.service cloudflared.service
journalctl --user -u hermes-webui.service -f

# ローカル確認（公開前の切り分け）
curl -fsS http://127.0.0.1:8787/health
curl -fsS http://127.0.0.1:8642/health          # agent API
curl -fsS http://127.0.0.1:9119/api/status | jq '.auth_required, .auth_providers'  # dashboard
podman ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'

# トンネル経由
curl -I https://hermes.example.com
curl -fsS https://agent.example.com/health       # API を公開した場合
curl -I https://dashboard.example.com            # Dashboard を公開した場合（401/302 でログインへ）
```

WebUI が外部から開けない場合は `cloudflared` のログで
`Unable to reach origin service` が出ていないか確認します。コンテナ名
`hermes-webui` が解決できているか、`podman exec cloudflared \
getent hosts hermes-webui` で確認できます。

---

## 5. ローカル config.yml 方式に切り替える

トークン方式を使わず、ファイルで ingress を管理する場合:

1. トンネル作成と DNS ルート:

   ```bash
   cloudflared tunnel create hermes
   cloudflared tunnel route dns hermes hermes.example.com
   cloudflared tunnel route dns hermes agent.example.com   # CLI/API を使う場合
   ```

2. `~/hermes/cloudflared/` を作り、`cloudflared.config.example.yml` を
   `config.yml` として配置し、credentials JSON も同じディレクトリに置く:

   ```bash
   mkdir -p ~/hermes/cloudflared
   cp hermes/cloudflared.config.example.yml ~/hermes/cloudflared/config.yml
   # credentials JSON は ~/.cloudflared/<TUNNEL-UUID>.json にある
   ```

3. `~/.config/containers/systemd/cloudflared.container` を次のように変更
   （`Exec` と `Volume` を差し替え、`EnvironmentFile` 行は削除）:

   ```ini
   [Container]
   ContainerName=cloudflared
   Image=docker.io/cloudflare/cloudflared:latest
   Network=hermes.network
   Exec=--no-autoupdate --config /etc/cloudflared/config.yml tunnel run
   Volume=%h/hermes/cloudflared:/etc/cloudflared:Z
   AutoUpdate=registry
   Restart=always
   ```

4. 反映:

   ```bash
   systemctl --user daemon-reload
   systemctl --user restart cloudflared.service
   ```

---

## 6. 外部クライアント / Web Dashboard を使う

ここでは WebUI 以外の使い方として、管理用 **Web Dashboard（9119）** と、
curl・OpenAI SDK・Open WebUI・各種 CLI クライアント向けの
**OpenAI 互換 API サーバー（8642）** を扱います。どちらも任意です。

### Web Dashboard（管理 UI）

`hermes-agent.container` が既定で `HERMES_DASHBOARD=1` /
`HERMES_DASHBOARD_HOST=0.0.0.0` を設定しているため、組み込みの管理
ダッシュボード（`http://hermes-agent:9119`）が gateway と並んで起動します。
config / API キー / Skills / MCP / Logs / Analytics / Cron / プロファイルなどを
ブラウザから管理できます。

非 loopback bind のため**認証ゲートが常時有効**です。basic 認証は使わず、
**Cloudflare Access を OIDC IdP として**使います（セットアップ手順は第 10 章）。
ダッシュボードの hostname は前段の Access（self-hosted アプリ）で保護し、
別に作成した Access の SaaS アプリ (OIDC) を Hermes の self-hosted OIDC
provider から認証に使います。

トンネルには Public Hostname を追加します（ローカル `config.yml` 方式は
`cloudflared.config.example.yml` に記載済み）:

- `dashboard.example.com` → `http://hermes-agent:9119`

`HERMES_DASHBOARD_PUBLIC_URL` を公開 URL と完全一致させてください
（OAuth の redirect URI と Host / Origin の DNS リバインディング対策に使用）。
確認と詳細は「10. Web Dashboard を Cloudflare Access (OIDC) で保護する」を参照。

### Agent API のルート追加

WebUI 以外（curl・OpenAI SDK・Open WebUI・各種 CLI クライアントなど）から使うには、
agent の **OpenAI 互換 API サーバー（8642）** をトンネルに公開します。
agent コンテナは `API_SERVER_ENABLED=true` / `API_SERVER_HOST=0.0.0.0` /
`API_SERVER_KEY` で既に有効化済みです。

トークン方式: Zero Trust → **Networks > Tunnels** → 対象トンネル → **Public Hostname** を追加:

- Subdomain / Domain: 例 `agent.example.com`
- Service: `HTTP`
- URL: `hermes-agent:8642`

ローカル `config.yml` 方式: `~/hermes/cloudflared/config.yml` の ingress に追記
（`cloudflared.config.example.yml` に記載済み）:

```yaml
  - hostname: agent.example.com
    service: http://hermes-agent:8642
```

### 使い方（Bearer トークン = `API_SERVER_KEY`）

```bash
export HERMES_API=https://agent.example.com
export HERMES_KEY="$(grep '^API_SERVER_KEY=' ~/hermes/hermes.env | cut -d= -f2-)"

# 疎通確認（/health は認証不要）
curl -fsS "$HERMES_API/health"

# モデル一覧（認証あり）
curl -fsS -H "Authorization: Bearer $HERMES_KEY" "$HERMES_API/v1/models"

# チャット補完
curl -fsS "$HERMES_API/v1/chat/completions" \
  -H "Authorization: Bearer $HERMES_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"Hello!"}]}'
```

OpenAI SDK（Python）:

```python
from openai import OpenAI
client = OpenAI(base_url="https://agent.example.com/v1", api_key="<API_SERVER_KEY>")
```

Open WebUI / LobeChat / LibreChat など:
接続先 URL を `https://agent.example.com/v1`、API Key を `API_SERVER_KEY` に設定。

ローカルの `hermes` をリモート agent のフロントエンドにする（gateway proxy モード）:
ローカル側の `~/.hermes/.env` に設定すると、ローカル gateway がエージェント処理を
リモートの API サーバーへ委譲します。

```bash
GATEWAY_PROXY_URL=https://agent.example.com
GATEWAY_PROXY_KEY=<API_SERVER_KEY>
```

### セキュリティ注意

- API サーバーは agent の全ツール（**terminal 実行を含む**）を公開します。
  `API_SERVER_KEY` は必須で、漏洩すると任意コマンド実行につながります。
- 公開する場合は **Cloudflare Access**（Service Token / OTP など）で前段を保護し、
  可能なら特定 IP に限定してください。
- Hermes Desktop の Remote Gateway は 8642 ではなく dashboard 側（9119）です。
  本構成では有効化済みなので、Desktop の **Settings → Gateways → Remote gateway** に
  `https://dashboard.example.com` を入力します（第 10 章参照）。
  Desktop は dashboard の OIDC ログインを利用しますが、前段の Cloudflare Access が
  非ブラウザの API プローブを HTML リダイレクトで返すため、Desktop からは
  接続できないことがあります（既知の制約）。

---

## 7. 運用コマンド

```bash
# リポジトリのユニット定義を pull で反映（3.1 で symlink 配置した場合）
git -C <リポジトリ> pull && systemctl --user daemon-reload

systemctl --user restart hermes-webui.service
systemctl --user stop cloudflared.service
journalctl --user -u hermes-agent.service -f

# バックアップ（第 8 章）
systemctl --user start hermes-backup.service
systemctl --user list-timers hermes-backup.timer
journalctl --user -u hermes-backup.service -f

# イメージの自動更新（AutoUpdate=registry を付けている場合）
podman auto-update
systemctl --user enable --now podman-auto-update.timer
```

> hermes-agent のイメージを更新した後は、`hermes-agent-src` ボリュームが
> 古いソースのまま残ります。agent と webui を止めてボリュームを削除し、
> 再作成すると新ソースが展開されます:
>
> ```bash
> systemctl --user stop hermes-webui.service hermes-agent.service
> podman volume rm hermes-agent-src
> systemctl --user start hermes-webui.service
> ```

---

## 8. バックアップ（SFTP・日次 4:00）

`hermes-home` ボリュームと `~/workspace` を gzip アーカイブにして OMV の NAS へ
SFTP で転送します。`hermes-backup.timer` が毎日 04:00 に
`hermes-backup.service` を起動し、既定で 14 日分を保持します。

- 対象: `hermes-home`（config / sessions / skills / memory / webui state）、`~/workspace`
- 対象外: `hermes-agent-src`（イメージから再生成可）、秘密の env（変更時に別途退避）
- 転送: `podman volume export | gzip` と `tar -czf` を SFTP で NAS へ
- 一貫性: 実行中だけ WebUI / agent を停止（webui 起動で agent も連鎖復帰）

### 8.1 OMV 側の準備

1. **Services > SSH** を有効化。
2. 専用ユーザ（例 `backup`）を作成し、データディスク上の退避先フォルダへ
   書込権限を付与。
3. そのユーザに FCOS の公開鍵を登録（**Users > SSH public keys**）。
4. 退避先の絶対パスを控える（例
   `/srv/dev-disk-by-uuid-<UUID>/backup/hermes`）。

### 8.2 FCOS 側の準備

```bash
# 鍵生成（未作成なら）。公開鍵は OMV の backup ユーザへ登録する。
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''

# ホスト鍵を登録（初回のみ）
ssh-keyscan omv.local >> ~/.ssh/known_hosts
```

`~/hermes/backup.env` を編集して接続情報を設定します:

```bash
BACKUP_SFTP_HOST=omv.local
BACKUP_SFTP_PORT=22
BACKUP_SFTP_USER=backup
BACKUP_SFTP_PATH=/srv/dev-disk-by-uuid-<UUID>/backup/hermes
BACKUP_SSH_KEY=%h/.ssh/id_ed25519
BACKUP_KEEP_DAYS=14
```

`BACKUP_SSH_KEY` の `%h` はホームディレクトリに展開されます。

### 8.3 有効化とテスト

```bash
systemctl --user daemon-reload
systemctl --user enable --now hermes-backup.timer

# 手動テスト（WebUI が数秒停止します）
systemctl --user start hermes-backup.service
journalctl --user -u hermes-backup.service -f

systemctl --user list-timers hermes-backup.timer
```

NAS 側に `hermes-home-YYYY-MM-DD.tar.gz` と `workspace-YYYY-MM-DD.tar.gz` が
できていれば成功です。

### 8.4 復元

```bash
systemctl --user stop hermes-webui.service hermes-agent.service

# NAS からアーカイブを取得して展開
sftp backup@omv.local:/srv/dev-disk-by-uuid-<UUID>/backup/hermes/hermes-home-YYYY-MM-DD.tar.gz
gunzip -c hermes-home-YYYY-MM-DD.tar.gz | podman volume import hermes-home -
tar -C ~ -xzf workspace-YYYY-MM-DD.tar.gz

# 秘密の env はパスワードマネージャ等から復元し、ユニットを再読込
git pull && systemctl --user daemon-reload
systemctl --user start hermes-webui.service
```

### 8.5 注意

- バックアップ中は WebUI / agent を停止します。日次 04:00 を想定。
- tar.gz は**平文**です。NAS 上の権限管理に注意し、必要なら OMV 側の
  btrfs/ZFS スナップショットで世代を補強してください。
- 保持日数は `BACKUP_KEEP_DAYS`。NAS 側は `-mtime` による削除のみ行います。
- `hermes.env` / `cloudflared.env` / `.cloudflared` は日次に含めません。
  変更したときだけ別途オフサイトへ退避してください。

---

## 9. トラブルシューティング

| 症状 | 対処 |
|---|---|
| `Permission denied` で起動失敗 | `~/hermes/hermes.env` の `WANTED_UID` / `WANTED_GID` が `id -u` / `id -g` と一致しているか確認（`HERMES_UID` / `HERMES_GID` は `10000` 固定） |
| agent が `usermod: UID '1000' already exists` で crash loop | `HERMES_UID` / `HERMES_GID` が `10000`、agent が `UserNS=keep-id:uid=10000,gid=10000` か確認 |
| cloudflared が数秒ごとに再起動 | 依存元の agent / webui が落ちていないか `systemctl --user status hermes-agent.service` を確認（`Requires` 連鎖） |
| WebUI が `Gateway endpoint not reachable` | `API_SERVER_KEY` を 16 文字以上で設定し、`HERMES_WEBUI_GATEWAY_API_KEY` と同一にする |
| dashboard が `Refusing to bind dashboard to 0.0.0.0 ... no auth providers are registered` で起動しない | `HERMES_DASHBOARD_OIDC_ISSUER` / `..._CLIENT_ID` / `..._CLIENT_SECRET` を設定し、`self_hosted` が `plugins.disabled` に無いことを確認（非 loopback bind は認証必須・fail-closed） |
| dashboard の `auth_providers` が空 | OIDC 3 値の設定漏れ、または `self_hosted` プラグイン無効化を確認（`/api/status` で確認） |
| dashboard の OIDC ログインが `invalid_client` で失敗 | `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` の不一致。Access の SaaS アプリ (OIDC) を確認 |
| dashboard の OIDC ログインが `redirect_uri` エラー | Cloudflare の Redirect URL を `<HERMES_DASHBOARD_PUBLIC_URL>/auth/callback` に一致させ、PKCE を有効化 |
| dashboard が `403` / Host で弾かれる | `HERMES_DASHBOARD_PUBLIC_URL` をトンネルの公開 URL と完全一致させる |
| dashboard が `Unable to reach origin service` | cloudflared の URL が `http://hermes-agent:9119` か確認（`podman exec cloudflared getent hosts hermes-agent`） |
| トンネルが origin に到達できない | `cloudflared` が `hermes.network` に参加しているか、URL が `http://hermes-webui:8787` か確認 |
| ログイン後にリダイレクトループ | `HERMES_WEBUI_ALLOWED_ORIGINS` と `*_TRUST_FORWARDED_*` の設定を確認 |
| `Unit hermes-webui.service not found` | Quadlet の構文エラー。`podman-system-generator --user --dryrun` で確認 |
| 再起動後に立ち上がらない | `loginctl enable-linger "$USER"` を実行 |
| 初回 pull がタイムアウト | `TimeoutStartSec=300`（設定済み）を延長 |
| ワークスペースに書き込めない | `~/workspace` の所有者がホスト UID と一致しているか、`:Z`（SELinux）を確認 |
| バックアップが `Host key verification failed` | `ssh-keyscan omv.local >> ~/.ssh/known_hosts` を実行 |
| バックアップが `Permission denied (publickey)` | OMV の `authorized_keys` と `BACKUP_SSH_KEY` のパスを確認 |
| バックアップ timer が動かない | `systemctl --user list-timers hermes-backup.timer` と `loginctl enable-linger "$USER"` を確認 |

`hermes-agent` は `UserNS=keep-id:uid=10000,gid=10000` で、ホスト UID をイメージ内
`hermes` ユーザーの UID/GID（`10000`）にマップします。`hermes-webui` は plain な
`UserNS=keep-id` でホスト UID をそのまま使います。両者とも共有ボリュームへの書き込みは
ホスト UID（`WANTED_UID` / `WANTED_GID`）所有になります。

---

## 10. Web Dashboard を Cloudflare Access (OIDC) で保護する

組み込み Web Dashboard（`hermes-agent:9119`）は非 loopback bind のため、Hermes
自身の認証ゲートが必須です。ここでは **Cloudflare Access を OIDC IdP** として使い、
basic 認証なしで運用するためのセットアップ手順をまとめます。

### 10.1 構成

- **前段**: Cloudflare Access の **self-hosted アプリ**が `dashboard.example.com`
  への到達を保護（ネットワーク到達の制御）。
- **認証**: 別に作成した Cloudflare Access の **SaaS アプリ (OIDC)** を IdP とし、
  Hermes の self-hosted OIDC provider が認可コード + PKCE でログイン。
- **経路**: Internet → Cloudflare Edge (Access) → cloudflared → hermes-agent:9119

```text
Browser ──HTTPS──▶ Cloudflare Edge (Access self-hosted)
                          │ Tunnel
                   cloudflared (hermes.network)
                          │ http://hermes-agent:9119
                   hermes-agent dashboard
                          │ OIDC (auth code + PKCE)
                          ▼
              Cloudflare Access SaaS (OIDC IdP)
```

### 10.2 前提

- Cloudflare アカウントで Zero Trust が有効。
- Cloudflare Access に IdP（メール OTP・Google 等）を 1 つ以上登録済み。
- `dashboard.example.com` をトンネルにルーティング済み（3.3）。
- Hermes イメージが `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` に対応
  （2026-06-30 以降の `:latest`。PR #55344）。
- `hermes-agent.container` は `HERMES_DASHBOARD=1` /
  `HERMES_DASHBOARD_HOST=0.0.0.0` / `HERMES_DASHBOARD_PORT=9119` を設定済み
  （このリポジトリの既定。変更不要）。

### 10.3 Cloudflare: 前段の self-hosted アプリ

1. Zero Trust → **Access controls > Applications > Create new application**。
2. **Self-hosted and private** を選択し、Public hostname に
   `dashboard.example.com` を追加。
3. **Access policies** で許可ポリシー（例: 自分のメールアドレス）を作成。
   Access は deny-by-default のため、許可ポリシーが必須。
4. 認証に使う IdP を選択。単一 IdP なら **Apply instant authentication** を
   有効化（Access ログインページを挟まず IdP へ直行）。
5. **Save**。この時点でダッシュボードは Access の背後に入ります。

### 10.4 Cloudflare: IdP になる SaaS アプリ (OIDC)

1. Zero Trust → **Access controls > Applications > Create new application**。
2. **SaaS application** を選び、Application 名（例 `hermes-dashboard`）を入力。
3. 認証方式に **OIDC** を選択。
4. **Redirect URLs** に `https://dashboard.example.com/auth/callback` を登録。
5. **PKCE** を有効化。
6. **Create** し、表示される次の 3 値を控える:
   - **Client ID**: `<client-id>`
   - **Client secret**: `<client-secret>`
   - **Issuer**:
     `https://<team>.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<client-id>`
7. **Access policies** で許可ポリシーを設定（deny-by-default）。

### 10.5 FCOS: 環境ファイルと反映

`~/hermes/hermes.env` に追記します（`hermes.env.example` の Dashboard 節にも
同じ変数があります）:

```bash
HERMES_DASHBOARD_OIDC_ISSUER=https://<team>.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<client-id>
HERMES_DASHBOARD_OIDC_CLIENT_ID=<client-id>
HERMES_DASHBOARD_OIDC_CLIENT_SECRET=<client-secret>
HERMES_DASHBOARD_OIDC_SCOPES=openid profile email
HERMES_DASHBOARD_PUBLIC_URL=https://dashboard.example.com
```

反映:

```bash
chmod 600 ~/hermes/hermes.env
systemctl --user restart hermes-webui.service   # agent 連鎖再起動で dashboard も再起動
```

### 10.6 確認

```bash
curl -fsS http://127.0.0.1:9119/api/status | jq '.auth_required, .auth_providers'
# => true
# => ["self-hosted"]   (バージョンにより "self_hosted")
```

`auth_providers` が空の場合は、`self_hosted` が `plugins.disabled` に入っていないか、
OIDC 3 値が揃っているかを確認します（第 9 章）。

ブラウザで `https://dashboard.example.com` を開く → `/login` →
**Sign in with Self-Hosted OIDC** → Cloudflare Access（既存セッションがあれば
ほぼそのまま）→ ダッシュボード。

### 10.7 注意

- discovery は `{issuer}/.well-known/openid-configuration`。Issuer の末尾スラッシュ
  は許容されますが、`iss` が一致する必要があります。
- トークン交換が `invalid_client` で失敗する場合は Client secret の不一致、
  `redirect_uri` エラーなら Redirect URL の不一致 or PKCE 未設定を確認します。
- TLS 終端が cloudflared コンテナ（非 loopback）のため、`dashboard.public_url` と
  併せて `dashboard.trusted_proxies` に cloudflared の IP を入れると
  `X-Forwarded-Proto` を信頼し、Cookie に `Secure` を付与できます。IP は
  `podman inspect cloudflared | jq '.[].NetworkSettings.Networks'` で確認し、
  `hermes-home` ボリューム内の `config.yaml` に記載します（任意の強化）。
- basic 認証は使わないため `HERMES_DASHBOARD_BASIC_AUTH_*` は設定しません。
