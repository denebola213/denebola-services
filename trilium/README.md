# Trilium Notes を Cloudflare Tunnel で公開（Podman Quadlet / rootless）

`triliumnext/trilium` を Podman Quadlet で常駐させ、`cloudflared` コンテナから
Cloudflare Tunnel 経由で外部公開する構成です。インバウンドポートを開けずに、
個人用ナレッジベースを HTTPS のホスト名で利用できます。

```text
                        ┌────────────────────┐
  Internet ── HTTPS ───▶│ Cloudflare Edge    │
                        │ (Access / ZeroTrust)│
                        └─────────┬──────────┘
                                  │ Tunnel (outbound のみ)
                        ┌─────────▼──────────┐
                        │ cloudflared-trilium│  trilium.network
                        └─────────┬──────────┘
                                  │ http://trilium:8080
                        ┌─────────▼──────────┐
                        │ trilium            │
                        │ :8080 (loopback)   │
                        └─────────┬──────────┘
                                  │
                        ~/trilium/data (SQLite)
```

- ネットワーク: `trilium`（Podman カスタムネットワーク、名前解決に使用）
- データ: `~/trilium/data` をバインドマウント（バックアップはディレクトリのコピー）
- ポート公開は `127.0.0.1:8080` のみ。外部到達は cloudflared 経由だけ
- `hermes/` のトンネルとは**別トンネル**（`cloudflared-trilium`）にして分離

---

## 1. 構成ファイル

| ファイル | 役割 |
| --- | --- |
| `trilium.network` | サービス用 Podman ネットワーク |
| `trilium.container` | Trilium 本体（loopback バインド、イメージはバージョン固定） |
| `cloudflared.container` | このサービス専用の Cloudflare Tunnel |
| `cloudflared.env.example` | `TUNNEL_TOKEN` の雛形（実ファイルは git 管理外） |

---

## 2. 前提

- Podman 4.4 以降（`podman-system-generator` 同梱）。Fedora CoreOS は標準。
- rootless ユーザーで lingering を有効化（FCOS なら `core`）。
- Cloudflare アカウントと、トンネルを割り当てるドメイン。
- データを置く `~/trilium/data` はホスト側に作成する。

```bash
sudo loginctl enable-linger "$USER"
```

---

## 3. セットアップ

### 3.1 データディレクトリを作成

```bash
mkdir -p ~/trilium/data
```

Trilium は初回起動時にこのディレクトリへ SQLite データベースを作ります。
UID は `keep-id:uid=1000,gid=1000` でホストユーザーに写像するため、
`~/trilium/data` は**ホストユーザー所有**のままにしてください。

### 3.2 Quadlet ユニットを配置

`hermes/` と同じく、ユニットはリポジトリへ symlink、環境ファイルはコピーします。

```bash
# このリポジトリのクローン先で実行
REPO="$(pwd)"

mkdir -p ~/.config/containers/systemd

ln -sf "$REPO"/trilium/trilium.network \
       "$REPO"/trilium/trilium.container \
       "$REPO"/trilium/cloudflared.container \
       ~/.config/containers/systemd/

cp trilium/cloudflared.env.example ~/trilium/cloudflared.env
chmod 600 ~/trilium/cloudflared.env
```

symlink は必ず絶対パスで作成します。壊れた相対 symlink は Quadlet generator が
読み飛ばすため、`cp` で上書きせず symlink のまま維持してください。
`git pull` でユニットを更新したら `systemctl --user daemon-reload` を実行します。

### 3.3 Cloudflare 側

1. Zero Trust ダッシュボード → **Networks > Tunnels > Create a tunnel**（Cloudflared）。
2. 表示されるトークンを `~/trilium/cloudflared.env` の `TUNNEL_TOKEN` に設定。
3. トンネルの **Public Hostname** を追加:
   - ホスト名: 例 `wiki.example.com`
   - Service: `HTTP`
   - URL: `trilium:8080`（cloudflared は `trilium.network` 上にいるためコンテナ名で解決）
4. **Access** で self-hosted アプリを作成し、`wiki.example.com` を保護する。
   - IdP は **Cloudflare**（`Restrict to account members` を ON）
   - ポリシー: Allow / Include に `Login method = Cloudflare`
5. 保存後、トンネルが `Healthy` になっていることを確認。

### 3.4 起動

```bash
systemctl --user daemon-reload

# 生成されるユニットを事前確認
/usr/lib/systemd/system-generators/podman-system-generator --user --dryrun

systemctl --user start trilium.service
```

`[Install] WantedBy=default.target` があるため `enable` は不要です。
`trilium.service` の起動で `cloudflared.service` も連鎖起動します。

---

## 4. 確認

```bash
systemctl --user status trilium.service cloudflared.service
journalctl --user -u trilium.service -f

# ローカル確認（公開前の切り分け）
curl -I http://127.0.0.1:8080
podman ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'

# トンネル経由
curl -I https://wiki.example.com
```

ブラウザで公開 URL を開くと、初回は**管理者アカウント作成画面**が出ます。
ユーザー名とパスワードを設定すると以降はログイン画面になります。
Cloudflare Access と Trilium のログインで二重になりますが、これは意図した構成です
（Access アプリを誤って外した場合の最後の壁）。

---

## 5. バックアップ

SQLite を稼働中にコピーすると壊れることがあるため、**停止してから**取得します。

```bash
systemctl --user stop trilium.service

tar -C "$HOME" -czf "$HOME/trilium-$(date +%F).tar.gz" trilium/data

systemctl --user start trilium.service
```

- 出力は**平文**です。退避先の権限管理に注意してください。
- 世代管理は NAS 側や `restic` などに任せるのが安全です。
- 復元は展開して `~/trilium/data` を戻し、`systemctl --user start trilium.service`。

---

## 6. アップグレード

イメージタグは意図的に固定しています（`:latest` は新マイナーバージョンへ自動で
移動し、同期や DB マイグレーションを跨ぐことがあります）。

1. `trilium.container` の `Image=` を新しいタグへ変更（例 `v0.106.1` → `v0.107.0`）。
2. バックアップを取得（第 5 章）。
3. 反映:

   ```bash
   systemctl --user daemon-reload
   systemctl --user restart trilium.service
   journalctl --user -u trilium.service -f
   ```

`v0.107.0` 以降は「コンテナを非 root で起動する」モードに対応します。
rootless で `chown` 関連の失敗が出る場合は、その版へ上げると解消する可能性があります。

---

## 7. トラブルシューティング

| 症状 | 対処 |
| --- | --- |
| `Unit trilium.service not found` | Quadlet の構文エラー。`podman-system-generator --user --dryrun` で確認 |
| 起動時に立ち上がらない | `loginctl enable-linger "$USER"` を実行したか確認 |
| `permission denied` でデータを書けない | `~/trilium/data` がホストユーザー所有か、`:Z`（SELinux）が付いているか確認 |
| 初回 pull がタイムアウト | `TimeoutStartSec=300`（設定済み）を延長 |
| トンネルが `Unable to reach origin service` | cloudflared が `trilium.network` に参加しているか、URL が `trilium:8080` か確認 |
| 公開 URL で Access ログイン後に 502 | コンテナ名の解決を確認: `podman exec cloudflared-trilium getent hosts trilium` |
| Access を外したら誰でも開ける | 仕様。Trilium 側のログインを必ず残す |
| SQLite が壊れた | 停止状態のバックアップから戻す。稼働中コピーは避ける |

---

## 8. セキュリティ上の注意

- `PublishPort` は `127.0.0.1` のみ。LAN へ直接公開しない。
- 外部到達は Cloudflare Access のポリシーで制御する。Access は deny-by-default のため、
  許可ポリシーが無いと誰も入れない（＝設定漏れは安全側に倒れる）。
- ETAPI トークン（`Options > ETAPI`）は Trilium の全データを操作できる。
  外部エージェントに渡す場合も、loopback かトンネル経由の HTTPS に限定する。
- TLS は Cloudflare のエッジで終端される。Cloudflare は本文を復号できるため、
  内容を事業者に見せたくない場合は WireGuard 経由の利用に留める。
