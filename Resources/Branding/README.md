# VoxType 图标

应用图标：`AppIcon.png`（1024 × 1024，透明 PNG）；生成原图：`VoxType-logo-source.png`。

五段圆角声波组成 V，右侧长竖线呼应文字插入光标。应用使用蓝色图标；菜单栏使用同形的单色简化版本，由 AppKit 绘制为模板图像并缓存，自动适应系统外观，不增加运行依赖。

`Resources/AppIcon.icns` 包含 macOS 常用尺寸，由 PNG 使用系统 `sips` 和 `iconutil` 打包。后续正常运行 `Scripts/build-app.sh` 会将图标写入应用资源。

图像使用内置 imagegen 生成，没有使用额外 API Key。生成提示词如下。

## 初始提示词

```text
Use case: logo-brand
Asset type: production macOS application icon for VoxType, a very lightweight microphone dictation utility that instantly types speech at the text cursor.
Primary request: Design ONE original, beautifully simple icon mark suggesting a letter V made from an audio waveform, with its last upright stroke subtly evoking a text insertion caret. A compact, bold, coherent geometric symbol, around five rounded strokes, legible at 16 pixels. Calm, precise and fast, suitable for a native Mac utility.
Composition: one centered icon only, square 1024x1024 canvas. A deep ink-blue rounded square macOS icon tile inset approximately 9% from all edges; outside the tile genuinely transparent. Inside, a large luminous pale cyan / white waveform-V mark with ample breathing space and strong contrast. Very restrained tile shading is acceptable; the foreground mark should be clean and nearly flat so it can also work as a one-color menu bar symbol.
Constraints: no text, no wordmark, no letters printed separately, no labels, no mockup, no device, no multiple variants, no photographic texture, no ornamental sparkles, no border decoration, no drop shadow extending outside the tile, no watermark. A finished icon asset, not a presentation board.
```

## 边缘整理提示词

```text
Use case: precise-object-edit / logo-brand. This image is the edit target. Preserve the exact existing VoxType design: blue rounded square tile, five pale cyan rounded waveform bars forming a V, the same proportions, positions, and colors. Change ONLY the exterior edge quality: remove every blue speckle, stray pixel, noise and fringe outside the rounded square. Make the tile boundary smooth, crisp, professionally anti-aliased, geometrically regular. Everything outside the tile must be fully transparent alpha zero, including the entire square canvas border and all four corners. Keep a clear transparent inset of approximately 8 percent on all four sides. No outer shadow. Do not add text, elements, borders or extra symbols. Output one finished square app icon asset.
```
