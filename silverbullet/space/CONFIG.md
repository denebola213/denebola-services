# Configuration

Space の設定。プラグはここで列挙する（追加したら `Plugs: Update` を実行）。

`mermaid` プラグは Mermaid 本体を jsDelivr から取得するため、クライアントに
インターネット接続が必要（プラグ自体には同梱されていない）。

```space-lua
config.set {
  plugs = {
    "github:silverbulletmd/silverbullet-mermaid/mermaid.plug.js"
  }
}
```
