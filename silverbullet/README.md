# SilverBullet を Cloudflare Tunnel で公開（Podman Quadlet / rootless）

`silverbulletmd/silverbullet` を Podman Quadlet で常駐させ、`silverbullet-cloudflared`
コンテナから Cloudflare Tunnel 経由で公開する構成です。人向け文書の正本として
`notes.st-albireo.net` で公開し、space には `~/workspace/notes` を使います。
`~/workspace/wiki`（LLM 用の wiki）とは別ディレクトリで、人間が読む文書だけを置きます。

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
| `silverbullet.container` | 本体（loopback バインド、タグ固定、`:z` で共有ラベル） |
| `silverbullet-cloudflared.container` | 専用 Cloudflare Tunnel |
| `silverbullet.env.example` | `SB_USER`（ログインフォームの認証情報）の雛形 |
| `cloudflared.env.example` | `TUNNEL_TOKEN` の雛形 |
| `space/STYLE.md` | space に置く Space Style（和文フォント・行間） |

ユニット名は Quadlet が**ファイル名**から生成するため、`cloudflared.container` ではなく
`silverbullet-cloudflared.container` にしています（他サービスと衝突させないため）。

## 前提

- Fedora CoreOS 上の rootless Podman（`loginctl enable-linger "$USER"` 済み）
- `127.0.0.1:3000` が空いていること
- space に使うディレクトリがホストユーザー所有であること（`~/workspace/notes`）

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

space 直下には `silverbullet/space/STYLE.md` をコピーしておく（任意だが推奨）。
既定フォント `iA-Mono` は和文グリフを持たず、`system-ui` 経由だと簡体字フォントに落ちる環境がある。
`STYLE.md` は欧文を OS の UI フォント、和文を和文専用ファミリに割り当て、行間も和文向けに広げる。
反映はクライアントの `System: Reload`。

```bash
cp "$REPO"/silverbullet/space/STYLE.md ~/workspace/notes/STYLE.md
```

認証は **HTTP Basic ではなく、`/.auth` のログインフォーム**（Cookie セッション）です。
`SB_USER` を変えたら `systemctl --user restart silverbullet.service` で反映されます。
なお初回起動時に space 直下へ `.silverbullet.auth.json`（認証状態、600）が作られます。

## 3. Cloudflare 側

1. Zero Trust → Networks → Tunnels → トンネル作成 → トークンを
   `~/silverbullet/cloudflared.env` の `TUNNEL_TOKEN` に貼る。
2. Public Hostname を追加（`notes.st-albireo.net`）:

   | 項目 | 値 |
   | --- | --- |
   | Type | `HTTP` |
   | URL | `silverbullet:3000` |

3. Access → Applications で `notes.st-albireo.net` に Allow ポリシーを付ける。

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

公開 URL 側は `curl -sI https://notes.st-albireo.net/` が
`location: https://<team>.cloudflareaccess.com/...` を返せば Access 有効です。

## 6. データとバックアップ

space は Markdown ファイルそのもの（`~/workspace/notes`）。DB も WAL も無いので、
停止不要でそのままコピー・git 管理できます。**バックアップはファイルコピーで十分**です。

`.silverbullet.auth.json`（認証状態と salt）も space に属するため、**space を移すときは一緒に
持っていく**こと。無い状態で作り直すと salt が変わり、ブラウザ側の暗号化キャッシュと
鍵が合わなくなる。

## 7. アップグレード

`Image=` のタグを書き換えて再起動します。`latest` は使わない方針です。

```bash
sed -i 's/silverbullet:2\.12\.1/silverbullet:X.Y.Z/' ~/denebola-services/silverbullet/silverbullet.container
systemctl --user daemon-reload && systemctl --user restart silverbullet.service
```

## 8. Trilium からの移行

旧構成（`trilium/` と Trilium 用トンネル）は廃止し、本構成に一本化した。文書は Trilium から
ETAPI で一度だけ書き出して space に置いている。

- 書き出し: `GET /etapi/notes/{noteId}/export?format=markdown`（サブツリーを ZIP で返す）
- 展開後に `Hermes/` を外し、拡張子なし／`.txt` を `.md` に揃える
  （SilverBullet は `.md` しかページ化しない）
- 以降は SilverBullet 側が正本。Trilium との同期は無く、`~/trilium/data`（SQLite）は控えとして残している

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
| 日本語が読みにくい | 既定フォントが `iA-Mono`（和文グリフなし）のため。space の `STYLE` ページに `space-style` ブロックを置き、`--ui-font` / `--editor-font` を差し替える。反映はクライアントの `System: Reload` |
| 日本語が**簡体字**で表示される | Han unification。`font-family` の先頭に `system-ui` や汎用 `sans-serif` を置くと、ロケール次第で Microsoft YaHei / Noto Sans CJK SC が選ばれる。欧文フォント（Segoe UI 等）→ 和文専用ファミリ（`Hiragino Sans` / `Yu Gothic UI` / `Noto Sans JP` / `Noto Sans CJK JP`）の順に明示し、`system-ui` は使わない |
| ログインで `This key does not match an existing local cache` | ブラウザのその origin のローカルデータを消す（DevTools → Application → Clear site data）。space を移すと `.silverbullet.auth.json` の salt が変わり、旧キャッシュの鍵と合わなくなる |
| 公開 URL が NXDOMAIN | CNAME が自動作成されていない。`<TUNNEL_ID>.cfargotunnel.com` への Proxied CNAME を手動で作成。LAN のルータが負キャッシュしている場合は dnsmasq を再起動 |
