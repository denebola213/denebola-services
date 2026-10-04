# Quadlet 導入手順（Podman + systemd）

Podman はデーモンレスなため、`podman compose up -d` や `--restart=always` だけでは
**再起動後にコンテナは自動起動しません**。
Quadlet を使うと `.container` / `.network` / `.volume` ファイルから systemd ユニットを
自動生成でき、**デーモンなしで起動時自動起動・再起動・ログ管理**を systemd に一本化できます。

> このリポジトリの `quadlet/` にサンプルのユニットファイルを置いています。

---

## 1. 前提

- Podman 4.4 以降（`podman-system-generator` 同梱）。Fedora CoreOS は標準で利用可。
- rootless で運用する場合、対象ユーザーで lingering を有効化する。

```bash
# rootless の場合（FCOS なら core ユーザー）
sudo loginctl enable-linger core

# ユニット配置ディレクトリ
mkdir -p ~/.config/containers/systemd
```

配置先の優先ルール:

| 実行ユーザー | 配置先 | `[Install]` |
| --- | --- | --- |
| rootless | `~/.config/containers/systemd/` | `WantedBy=default.target` |
| root | `/etc/containers/systemd/` | `WantedBy=multi-user.target` |
| rootless（管理者配置） | `/etc/containers/systemd/users/<UID>/` | `WantedBy=default.target` |

---

## 2. ユニットファイルを配置

`quadlet/` 内のファイルを配置先へコピーします。

```bash
cp quadlet/*.network quadlet/*.volume quadlet/*.container \
   ~/.config/containers/systemd/
```

### `app.network`

```ini
[Network]
NetworkName=app
```

### `app.volume`

```ini
[Volume]
VolumeName=app-data
```

### `db.container`

```ini
[Container]
Image=docker.io/library/postgres:16
ContainerName=db
Network=app.network
Volume=app.volume:/var/lib/postgresql/data:Z
Environment=POSTGRES_PASSWORD=secret
Restart=always
```

### `app.container`

```ini
[Unit]
Requires=db.service
After=db.service

[Container]
Image=docker.io/myorg/myapp:latest
Network=app.network
PublishPort=8080:80
Environment=DATABASE_URL=postgres://postgres:secret@db:5432
AutoUpdate=registry
Restart=always

[Install]
WantedBy=default.target
```

---

## 3. 反映と起動

```bash
systemctl --user daemon-reload
systemctl --user start app.service          # 依存関係から db も起動

systemctl --user status app.service
journalctl --user -u app.service -f
```

Quadlet が生成するユニットは systemd の **一時ユニット** のため `systemctl enable` は不要です。
`.container` に `[Install] WantedBy=default.target` を書いておけば、
**起動時に自動起動** します（`podman-restart.service` は不要）。

root で動かす場合は `--user` を外し、`WantedBy=multi-user.target` を使用します。

---

## 4. compose からの移行

### 手動変換の対応表

| docker compose | Quadlet |
| --- | --- |
| `image:` | `Image=` |
| `container_name:` | `ContainerName=` |
| `ports:` | `PublishPort=` |
| `volumes:` | `Volume=`（`:Z` で SELinux ラベル付与） |
| `networks:` | `Network=` |
| `environment:` | `Environment=` / `EnvironmentFile=` |
| `env_file:` | `EnvironmentFile=` |
| `command:` | `Exec=` |
| `entrypoint:` | `Entrypoint=` |
| `restart: always` | `Restart=always`（`[Container]` と `[Service]` の両方） |
| `depends_on:` | `[Unit] Requires=` / `After=` |
| `healthcheck:` | `HealthCmd=` / `HealthInterval=` |
| `secrets:` | `Secret=` |

### 自動変換ツール `podlet`

```bash
mkdir -p quadlet-out

# podlet を podman コンテナで実行（--install で [Install] 行も付与）
podman run --rm -v "$PWD":/work -w /work \
  ghcr.io/containers/podlet \
  --install --file quadlet-out/ compose compose.yaml
```

`--install` を付けると `[Install]` セクションが自動で入ります。
生成物を確認してから配置先へコピーしてください。

```bash
cp quadlet-out/* ~/.config/containers/systemd/
systemctl --user daemon-reload
```

---

## 5. 運用コマンド

```bash
# 生成される systemd ユニットを事前確認
/usr/lib/systemd/system-generators/podman-system-generator --user --dryrun
systemctl --user cat app.service

systemctl --user stop app.service
systemctl --user restart app.service
systemctl --user list-units 'app*'

# 削除
rm ~/.config/containers/systemd/app.container
systemctl --user daemon-reload
```

### イメージの自動更新

`AutoUpdate=registry` を付けた場合:

```bash
podman auto-update
systemctl --user enable --now podman-auto-update.timer   # rootless
# root の場合は systemctl enable --now podman-auto-update.timer
```

---

## 6. トラブルシューティング

| 症状 | 対処 |
| --- | --- |
| `Unit app.service not found` | 構文エラーで generator が失敗。`--dryrun` で確認 |
| 起動時に立ち上がらない | rootless で `loginctl enable-linger` 未設定。`Linger=yes` を確認 |
| 初回 pull で timeout | `[Service] TimeoutStartSec=300` を設定 |
| ボリュームに書けない | SELinux ラベル `:Z` を付与 |
| ログが見えない | `journalctl --user -u <name>.service` |

---

## 7. 参考: compose のまま自動起動させる場合

Quadlet を使わず compose を維持する場合でも、以下で自動起動は可能です。

```yaml
# compose.yaml
services:
  app:
    image: ...
    restart: always
```

```bash
# rootless
sudo loginctl enable-linger <user>
systemctl --user enable --now podman-restart.service

# root
sudo systemctl enable --now podman-restart.service
```

`podman-restart.service` が `restart=always` のコンテナを起動時に復帰させます。
ただし systemd と二重管理になりがちなので、常駐運用では **Quadlet を推奨** します。
