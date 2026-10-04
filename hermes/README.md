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
                        └─────────┬──────────┘
                                  │ http://hermes-webui:8787
                        ┌─────────▼──────────┐
                        │ hermes-webui :8787 │
                        └───┬──────────┬─────┘
              hermes-home   │          │  hermes-agent-src (ro)
                        ┌───▼──────────▼─────┐
                        │ hermes-agent :8642 │  (gateway API)
                        └────────────────────┘
```

- ネットワーク: `hermes`（Podman カスタムネットワーク、名前解決に使用）
- ボリューム: `hermes-home`（config/sessions/skills/memory）、`hermes-agent-src`（エージェントのソース）
- ポート公開は両方 `127.0.0.1` のみ。外部到達は cloudflared 経由だけ。
- WebUI 用（`hermes-webui:8787`）に加え、CLI/API 用に agent の
  OpenAI 互換 API（`hermes-agent:8642`）も任意でトンネルへ追加できます（第 6 章）。

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
id -u   # HERMES_UID / WANTED_UID に入れる
id -g   # HERMES_GID / WANTED_GID に入れる
```

- `HERMES_UID` / `HERMES_GID` と `WANTED_UID` / `WANTED_GID` を **同じホスト UID/GID** に設定。
- `API_SERVER_KEY` と `HERMES_WEBUI_GATEWAY_API_KEY` を **同じ長いランダム文字列**（16 文字以上）に。
- `HERMES_WEBUI_PASSWORD` を設定（外部公開では必須）。
- `HERMES_WEBUI_ALLOWED_ORIGINS` に公開ホスト名（例 `https://hermes.example.com`）。

`~/hermes/cloudflared.env`:

- `TUNNEL_TOKEN` に Cloudflare のトンネルトークンを設定。

### 3.3 Cloudflare 側

1. Zero Trust ダッシュボード → **Networks > Tunnels > Create a tunnel**（Cloudflared）。
2. 表示されるトークンを `~/hermes/cloudflared.env` の `TUNNEL_TOKEN` に貼り付け。
3. トンネルの **Public Hostname** を追加:
   - WebUI: `hermes.example.com` → Service `HTTP` → URL `hermes-webui:8787`
   - Agent API（CLI/API 用・任意）: `agent.example.com` → Service `HTTP` → URL `hermes-agent:8642`
     （cloudflared は `hermes` ネットワーク上にいるため、コンテナ名で名前解決できます）
4. 必要なら **Access** ポリシーでメール OTP 等を追加（WebUI パスワードと二重防御）。
   Agent API を公開する場合は Access での保護を強く推奨（第 6 章）。
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
podman ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'

# トンネル経由
curl -I https://hermes.example.com
curl -fsS https://agent.example.com/health       # API を公開した場合
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

## 6. CLI / API クライアントから agent を使う

WebUI 以外（curl・OpenAI SDK・Open WebUI・各種 CLI クライアントなど）から使うには、
agent の **OpenAI 互換 API サーバー（8642）** をトンネルに公開します。
agent コンテナは `API_SERVER_ENABLED=true` / `API_SERVER_HOST=0.0.0.0` /
`API_SERVER_KEY` で既に有効化済みです。

### ルート追加

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
- Hermes Desktop の Remote Gateway は 8642 ではなく dashboard 側（9119、
  `hermes serve` / `hermes dashboard`）です。使う場合は agent に
  `HERMES_DASHBOARD=1` と `HERMES_DASHBOARD_HOST=0.0.0.0` を追加し、
  非 loopback bind のため `HERMES_DASHBOARD_BASIC_AUTH_*` または OAuth を
  設定してください（`cloudflared` には `hermes-agent:9119` を追加）。

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
| `Permission denied` で起動失敗 | `~/hermes/hermes.env` の UID/GID が `id -u` / `id -g` と一致しているか確認 |
| WebUI が `Gateway endpoint not reachable` | `API_SERVER_KEY` を 16 文字以上で設定し、`HERMES_WEBUI_GATEWAY_API_KEY` と同一にする |
| トンネルが origin に到達できない | `cloudflared` が `hermes.network` に参加しているか、URL が `http://hermes-webui:8787` か確認 |
| ログイン後にリダイレクトループ | `HERMES_WEBUI_ALLOWED_ORIGINS` と `*_TRUST_FORWARDED_*` の設定を確認 |
| `Unit hermes-webui.service not found` | Quadlet の構文エラー。`podman-system-generator --user --dryrun` で確認 |
| 再起動後に立ち上がらない | `loginctl enable-linger "$USER"` を実行 |
| 初回 pull がタイムアウト | `TimeoutStartSec=300`（設定済み）を延長 |
| ワークスペースに書き込めない | `~/workspace` の所有者がホスト UID と一致しているか、`:Z`（SELinux）を確認 |
| バックアップが `Host key verification failed` | `ssh-keyscan omv.local >> ~/.ssh/known_hosts` を実行 |
| バックアップが `Permission denied (publickey)` | OMV の `authorized_keys` と `BACKUP_SSH_KEY` のパスを確認 |
| バックアップ timer が動かない | `systemctl --user list-timers hermes-backup.timer` と `loginctl enable-linger "$USER"` を確認 |

`UserNS=keep-id` はホスト UID をコンテナ内の同一 UID に割り当てます。
`HERMES_UID` / `WANTED_UID` を必ずホスト UID に合わせてください。
