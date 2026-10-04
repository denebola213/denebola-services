# Fedora CoreOS インストール手順（Butane / Ignition）

不変（immutable）なコンテナホスト **Fedora CoreOS (FCOS)** をセットアップする手順です。
設定は宣言的な **Butane**（`config.bu`）で管理し、**Ignition**（`config.ign`）へ変換して
インストール時に流し込みます。

```text
config.bu ──(butane)──▶ config.ign ──(coreos-installer)──▶ ディスクへインストール
                                                              └─ 初回起動時に Ignition 適用
```

---

## 0. このディレクトリのファイル

| ファイル | 役割 | git 管理 |
| --- | --- | --- |
| `config.bu` | Butane 設定（人が編集する唯一のソース） | する |
| `config.ign` | `config.bu` から生成される Ignition JSON | しない（生成物） |
| `butane` | Butane 本体（ダウンロードするツール） | しない |

`butane` バイナリと ISO、生成物 `config.ign` はリポジトリの `.gitignore` で除外しています。

---

## 1. ツールの入手

### Butane

`fcos/` 内に実行ファイルとして配置します（リポジトリには含めません）。

```bash
# バージョンは https://github.com/coreos/butane/releases を確認
VER=0.29.0
curl -fsSL -o butane \
  "https://github.com/coreos/butane/releases/download/v${VER}/butane-x86_64-unknown-linux-gnu"
chmod +x butane
./butane --version
```

### Fedora CoreOS の ISO をダウンロード

`coreos-installer` のコンテナイメージで取得できます（`fcos/` で実行）。

```bash
podman run --rm --pull=always -v "$PWD":/data -w /data \
  quay.io/coreos/coreos-installer:release download -f iso
```

> ダウンロードした ISO は巨大なためコミットしません。検証用途で残す場合も
> `fcos/*.iso` は `.gitignore` 済みです。

---

## 2. Ignition の生成

`config.bu` を編集したら必ず `config.ign` を再生成します。

```bash
./butane config.bu -o config.ign
```

構文チェックだけ行う場合:

```bash
./butane --check config.bu
```

### `config.bu` の内容（現状）

```yaml
variant: fcos
version: 1.6.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ssh-ed25519 AAAA... denebola213@desktop
```

`core` ユーザーに公開鍵を登録するだけの最小構成です。パッケージ追加、systemd ユニット、
ファイル配置などは Butane の各セクションに追記してから再生成します。

---

## 3. インストール

対象ディスクは **上書きされます**。`lsblk` などでデバイス名を必ず確認してください。
以下 `/dev/sda` は例です。

### 方法 A: ライブ ISO から手動インストール（推奨・確認しながら）

1. ISO を書き込んだ USB / 仮想マシンの CD から起動する。
2. ライブ環境のコンソールで、`config.ign` を入手する（USB 内に置く、HTTP 配信、
   `coreos-installer iso ignition embed` など）。
3. インストール:

   ```bash
   sudo coreos-installer install /dev/sda \
     --ignition-file config.ign \
     --copy-network
   sudo reboot
   ```

   - `--copy-network`: ライブ環境の NetworkManager 設定をインストール先へ引き継ぐ。
     静的 IP 構成のときに便利。
   - `--ignition-file` の代わりに `--ignition-url http://<host>/config.ign`、
     `--ignition-file config.bu`（Butane 直接指定も可）も利用できます。

### 方法 B: 完全自動インストール（カーネル引数）

ISO を起動し、ブートメニューでカーネル引数を編集（isolinux は `Tab`、GRUB は `e`）
して以下を追加。インストール完了後に自動で再起動します。

```text
coreos.inst.install_dev=/dev/sda
coreos.inst.ignition_url=http://192.168.1.10:8000/config.ign
```

設定配信は同じディレクトリで簡易サーバーを立てるのが手軽です。

```bash
python3 -m http.server 8000   # fcos/ 内で実行
```

### 方法 C: ISO をカスタマイズして自動化（`iso customize`・推奨の自動化）

```bash
coreos-installer iso customize \
  --dest-device /dev/sda \
  --dest-ignition config.ign \
  -o custom.iso fedora-coreos-*.iso
```

`custom.iso` を起動すると確認なしで `/dev/sda` にインストールされ、
完了後に自動再起動します。ネットワークを固定する場合は `--network-keyfile` を追加します。

### 仮想マシンで試す場合

```bash
virt-install --name coreos --ram 4096 --vcpus 2 --disk size=20 \
  --cdrom custom.iso --network default --graphics none
```

---

## 4. 初回起動後

1. SSH 接続（`config.bu` の公開鍵が有効）:

   ```bash
   ssh core@<IP>
   ```

2. rootless 運用のため lingering を有効化:

   ```bash
   sudo loginctl enable-linger core
   ```

3. Quadlet の配置先を作成:

   ```bash
   mkdir -p ~/.config/containers/systemd ~/workspace
   ```

4. 以降はリポジトリの他手順へ:
   - `../quadlet/QUADLET.md` — Podman + systemd のユニット運用
   - `../hermes/README.md` — Hermes + Cloudflare Tunnel の常駐構成

---

## 5. `config.bu` の拡張例

再生成（`./butane config.bu -o config.ign`）を忘れずに。

```yaml
variant: fcos
version: 1.6.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ssh-ed25519 AAAA...
      groups:
        - wheel
      shell: /bin/bash
storage:
  files:
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: control01
systemd:
  units:
    - name: podman.socket
      enabled: true
```

> FCOS は不変OSです。設定変更はこの `config.bu` を更新して再インストールするか、
> 初回起動後に `rpm-ostree` を Butane 経由で管理してください。
> `ssh_authorized_keys` の変更など事後の設定投入は
> `sudo /usr/sbin/coreos-installer ...` ではなく `ignition` 再適用系の手順が必要です。

---

## 6. トラブルシューティング

| 症状 | 対処 |
| --- | --- |
| Ignition が適用されない | `config.ign` を再生成したか、URL/ファイル配置を確認。ログは `journalctl -u ignition-firstboot-complete` |
| `coreos.inst` で自動インストールしない | カーネル引数の綴りと `coreos.inst.install_dev` の指定を確認 |
| HTTP の Ignition が拒否される | HTTPS を使うか、`--insecure-ignition` / `--ignition-hash` で許可 |
| ネットワークがインストール後に切れる | 手動時は `--copy-network`、自動時は `--network-keyfile` で設定を引き継ぐ |
| 間違ったディスクに入れた | `coreos-installer install` 実行前に `lsblk -o NAME,SIZE,MODEL` で必ず確認 |
| SSH で入れない | 公開鍵の貼り付けミス、`core` ユーザー名、`config.ign` の埋め込み有無を確認 |

---

## 参考

- CoreOS Installer: <https://coreos.github.io/coreos-installer/>
- Butane: <https://coreos.github.io/butane/>
- Fedora CoreOS Docs: <https://docs.fedoraproject.org/en-US/fedora-coreos/>
