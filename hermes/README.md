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

```bash
mkdir -p ~/.config/containers/systemd ~/hermes ~/workspace

cp hermes/*.network hermes/*.volume hermes/*.container \
   ~/.config/containers/systemd/

cp hermes/hermes.env.example     ~/hermes/hermes.env
cp hermes/cloudflared.env.example ~/hermes/cloudflared.env
chmod 600 ~/hermes/hermes.env ~/hermes/cloudflared.env
```

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
systemctl --user restart hermes-webui.service
systemctl --user stop cloudflared.service
journalctl --user -u hermes-agent.service -f

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

## 8. トラブルシューティング

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

`UserNS=keep-id` はホスト UID をコンテナ内の同一 UID に割り当てます。
`HERMES_UID` / `WANTED_UID` を必ずホスト UID に合わせてください。
