# SilverBullet を Cloudflare Tunnel で公開（Podman Quadlet / rootless）

`silverbulletmd/silverbullet` を Podman Quadlet で常駐させ、`silverbullet-cloudflared`
コンテナから Cloudflare Tunnel 経由で公開する構成です。Trilium との比較用に、
**同じ Markdown ディレクトリ**（`~/workspace/wiki`）を space として読みます。

```text
Internet ── HTTPS ──▶ Cloudflare Edge
                          │  (Access / ZeroTrust)
                          │ Tunnel (outbound のみ)
                  ┌───────▼────────────┐
                  │ silverbullet-cloudflared │  silverbullet.network
                  └───────┬────────────┘
                          │ http://silverbullet:3000
                  ┌───────▼────────────┐
                  │ silverbullet       │
                  │  /data ← markdown  │
                  └────────────────────┘
```

## 構成ファイル

| ファイル | 内容 |
| --- | --- |
| `silverbullet.network` | サービス専用ネットワーク |
| `silverbullet.container` | 本体（loopback バインド、タグ固定） |
| `silverbullet-cloudflared.container` | 専用 Cloudflare Tunnel |
| `silverbullet.env.example` | `SB_USER`（ログインフォームの認証情報）の雛形 |
| `cloudflared.env.example` | `TUNNEL_TOKEN` の雛形 |

ユニット名は Quadlet が**ファイル名**から生成するため、`cloudflared.container` ではなく
`silverbullet-cloudflared.container` にしています（他サービスと衝突させないため）。

## 前提

- Fedora CoreOS 上の rootless Podman（`loginctl enable-linger "$USER"` 済み）
- `127.0.0.1:3000` が空いていること
- space に使うディレクトリがホストユーザー所有であること（`~/workspace/wiki`）

## 1. ユニットの配置

```bash
REPO=~/denebola-services
mkdir -p ~/.config/containers/systemd ~/silverbullet

ln -sf "$REPO"/silverbullet/silverbullet.network \
       "$REPO"/silverbullet/silverbullet.container \
       "$REPO"/silverbullet/silverbullet-cloudflared.container \
       ~/.config/containers/systemd/
```

## 2. 環境ファイル

```bash
cp "$REPO"/silverbullet/silverbullet.env.example ~/silverbullet/silverbullet.env
cp "$REPO"/silverbullet/cloudflared.env.example ~/silverbullet/cloudflared.env
chmod 600 ~/silverbullet/*.env
```

`SB_USER` は `user:password` 形式で、**このファイルは必須**です（Quadlet は `EnvironmentFile=` の
`-`（任意）指定に対応しておらず、無いと起動しません）。値を空にすると認証なしになり、
Cloudflare Access を通れば誰でも編集できます。

認証は **HTTP Basic ではなく、`/.auth` のログインフォーム**（Cookie セッション）です。
`SB_USER` を変えたら `systemctl --user restart silverbullet.service` で反映されます。
なお初回起動時に space 直下へ `.silverbullet.auth.json`（認証状態、600）が作られます。

## 3. Cloudflare 側

1. Zero Trust → Networks → Tunnels → トンネル作成 → トークンを
   `~/silverbullet/cloudflared.env` の `TUNNEL_TOKEN` に貼る。
2. Public Hostname を追加（例 `sb.example.com`）:

   | 項目 | 値 |
   | --- | --- |
   | Type | `HTTP` |
   | URL | `silverbullet:3000` |

3. Access → Applications で `sb.example.com` に Allow ポリシーを付ける。

トークン方式の ingress は Cloudflare 側の設定なので、変更しても cloudflared の再起動は不要です。
Public Hostname を追加しても DNS の CNAME が作られない場合は、`<TUNNEL_ID>.cfargotunnel.com`
への CNAME（Proxied）を手動で作成してください。

## 4. 起動

```bash
podman-system-generator --user --dryrun   # 構文確認
systemctl --user daemon-reload
systemctl --user start silverbullet.service
```

`[Install] WantedBy=default.target` があるため `enable` は不要です。

トンネルトークンが未設定のまま起動すると `silverbullet-cloudflared` が再起動を繰り返すので、
先に環境ファイルを埋めるか、次のように止めておきます。

```bash
systemctl --user mask silverbullet-cloudflared.service
# トークン投入後
systemctl --user unmask silverbullet-cloudflared.service
systemctl --user start silverbullet-cloudflared.service
```

## 5. 確認

```bash
systemctl --user is-enabled silverbullet.service
systemctl --user is-active silverbullet.service silverbullet-cloudflared.service
podman ps --filter name=silverbullet --format '{{.Names}} | {{.Status}} | {{.Ports}}'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/
ss -ltn | grep 3000                       # 127.0.0.1 のみか
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/index.md   # 未認証なら 401
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/.auth       # ログインフォームは 200

# 認証が通るか（Cookie が返れば成功）
curl -s -D - -o /dev/null -X POST \
  -d 'username=admin&password=********' http://127.0.0.1:3000/.auth | grep -i set-cookie
```

公開 URL 側は `curl -sI https://sb.example.com/` が
`location: https://<team>.cloudflareaccess.com/...` を返せば Access 有効です。

## 6. データとバックアップ

space は Markdown ファイルそのもの（`~/workspace/wiki`）。DB も WAL も無いので、
停止不要でそのままコピー・git 管理できます。Trilium と違い**バックアップはファイルコピーで十分**です。

## 7. アップグレード

`Image=` のタグを書き換えて再起動します。`latest` は使わない方針です。

```bash
sed -i 's/silverbullet:2\.12\.1/silverbullet:X.Y.Z/' ~/denebola-services/silverbullet/silverbullet.container
systemctl --user daemon-reload && systemctl --user restart silverbullet.service
```

## 8. Trilium との比較観点

| 観点 | SilverBullet | Trilium |
| --- | --- | --- |
| データ形式 | Markdown ファイル（外部エディタ・git 可） | SQLite（アプリ内で完結） |
| 人物の編集 | エディタ的（ライブプレビュー、`[[link]]`） | ノートツリー（リッチ、子ノート構造） |
| クリッパー | 公式なし（ブックマークレット等で代替） | 公式（全文・スクショ・`clipperInbox`） |
| API | HTTP（`/.fs` 等）、Space Lua | ETAPI（REST、`/etapi/*`） |
| AI/MCP | なし（Space Lua で自作） | 内蔵 MCP + 複数プロバイダ |
| モバイル | PWA（オフライン可） | PWA（オフライン不可） |
| バックアップ | ファイルコピー | 停止 or 組み込みバックアップ |

同じ space を両方から開けるので、**編集はどちらか一方に決める**のが安全です
（同時に開いて保存すると後勝ちになります）。

## 9. トラブルシューティング

| 症状 | 対処 |
| --- | --- |
| `su: must be suid to work properly` で落ちる | `User=1000:1000` が外れている。rootless では entrypoint の `su` が使えない |
| 書き込んだファイルが `core` 以外の所有になる | `UserNS=keep-id:uid=1000,gid=1000` と `User=1000:1000` が揃っているか確認 |
| `bind: address already in use` | 前回の検証コンテナの `pasta` がポートを掴んでいる。`ss -ltnp \| grep 3000` で PID を特定して kill |
| 公開 URL が 502 | ingress の URL が `silverbullet:3000` か、両コンテナが `silverbullet.network` にいるか確認 |
| 公開 URL が 200 で Access の 302 にならない | Access アプリ未作成。origin がそのまま露出している |
| `parsing file ".../-/path/to.env"` で起動失敗 | Quadlet は `EnvironmentFile=-`（任意指定）を解釈せず、`-` がパス扱いになる。`-` を外し、ファイルを先に作る |
| 設定が反映されない | `.container` を変えたら `systemctl --user daemon-reload` が必要 |
