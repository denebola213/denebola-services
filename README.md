# denebola-services

自宅サーバー（Fedora CoreOS + Podman）でセルフホストするサービスの設定・手順を
まとめるリポジトリです。

| ディレクトリ | 内容 |
| --- | --- |
| [`fcos/`](fcos/README.md) | Fedora CoreOS のインストール（Butane / Ignition） |
| [`quadlet/`](quadlet/QUADLET.md) | Podman Quadlet の導入手順 |
| [`hermes/`](hermes/README.md) | Hermes Agent + WebUI + Dashboard の Cloudflare Tunnel 公開構成 |

## Markdown lint

ドキュメントの体裁を `markdownlint-cli2` で統一します。PR と `main` への push 時に
GitHub Actions（`.github/workflows/markdownlint.yml`）で自動チェックされます。

設定ファイル:

| ファイル | 役割 |
| --- | --- |
| `.markdownlint.json` | ルール設定 |
| `.markdownlint-cli2.jsonc` | 対象 glob・除外・設定ファイルの指定 |
| `.github/workflows/markdownlint.yml` | CI での実行 |

### ルール方針

- `MD013`（行長）: 無効。日本語は単語区切りが無く 80 文字制限が適さないため。
- `MD060`（テーブル記法）: 無効。`|---|---|` の compact 記法で統一しているため。
- 構成図など言語指定が無いコードブロックは、言語に `text` を指定します。

### ローカルでの実行

Node.js がある環境:

```bash
npx markdownlint-cli2
```

Node.js がない環境（Podman）:

```bash
podman run --rm -v "$PWD:/workdir:ro,Z" docker.io/davidanson/markdownlint-cli2:latest
```

Node.js がない環境（Docker）:

```bash
docker run --rm -v "$PWD:/workdir:ro" davidanson/markdownlint-cli2:latest
```

補足:

- 設定は `/workdir` にバインドマウントしたディレクトリから自動で読み込まれます。
  引数を渡さない場合は `.markdownlint-cli2.jsonc` の `globs` が使われます。
- 特定ファイルだけ検査する場合は glob を引数で渡します。
  例: `... davidanson/markdownlint-cli2:latest "hermes/**/*.md"`
- 再現性のため、`:latest` ではなくバージョン固定（例 `:v0.23.3`）も利用できます。
- Podman の `:Z` は SELinux ラベル用のため、rootless / FCOS では付与します。
