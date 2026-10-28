---
tags: meta
---
# Style

SilverBullet の既定フォント（`iA-Mono`）は和文グリフを持たないため、日本語が
ブラウザ任せのフォールバックになり読みづらくなる。欧文は OS の UI フォント、和文は
**和文専用ファミリ**（Hiragino / Yu Gothic / Noto Sans JP など）に明示的に落とす。
`system-ui` を先頭に置くと CJK が簡体字フォントで描画される環境があるため使わない。

等幅（コードブロック・インラインコード）だけは `--editor-monospace-font` で維持する。

```space-style
/* priority: 20 */

/*
  system-ui を先頭に置くと、ロケールによっては CJK を簡体字フォント
  (Microsoft YaHei / Noto Sans CJK SC など) で描画してしまう。
  欧文は各 OS の UI フォント、和文は和文専用ファミリに明示的に落とす。
*/
html {
  /* 汎用ファミリ（sans-serif）は最後にだけ置く。途中に置くと後続の和文指定が無効になる */
  --font-latin: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial;
  --font-jp: "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic UI", "Yu Gothic",
    "Meiryo UI", "Meiryo", "Noto Sans JP", "Noto Sans CJK JP", "Source Han Sans JP",
    "IPAexGothic", "IPAPGothic";

  --ui-font: var(--font-latin), var(--font-jp), sans-serif !important;
  --editor-font: var(--font-latin), var(--font-jp), sans-serif !important;
  --editor-monospace-font: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas,
    "Noto Sans Mono CJK JP", "Noto Sans Mono", monospace !important;
}

/* 和文は既定の行間（1.4）だと詰まって見えるので広げる。
   エディタは #sb-editor > .cm-editor > .cm-content なので .cm-editor 経由で当てる */
html .cm-editor .cm-content {
  line-height: 1.8 !important;
}

/* コードブロックは等幅のまま、行間だけ少し詰める */
html .cm-editor .cm-line.HyperMD-codeblock,
html .cm-editor pre,
html .cm-editor code {
  line-height: 1.55 !important;
}
```
