# README graphics: sources and reproduction

The English and Chinese READMEs embed three locally versioned SVGs each: the advantage summary, product-approach comparison and measured ASR chart. PNG copies are provided for sharing. The graphics have no external images, scripts or fonts to download and are not bundled in the macOS app.

## Evidence

- **VoxType**: [LICENSE](../../LICENSE), [Package.swift](../../Package.swift), [TextInserter](../../Sources/VoxTypeApp/TextInserter.swift), [SessionController](../../Sources/VoxTypeApp/SessionController.swift) and [API request builder](../../Sources/VoxTypeCore/DoubaoProtocol.swift). Client subscription fee is zero, not total service cost. Hosted Doubao ASR still needs the user's own account and paid/quota usage. No local inference model is shipped. Automatic dictation avoids clipboard access; the explicit Copy Last Result command still copies normally.
- **Wispr Flow**: [official product page](https://wisprflow.ai/) describes writing cleanup/formatting, cross-platform use and 100+ languages. Its [pricing page](https://wisprflow.ai/pricing) provides a free tier and paid Pro. No assertion is made about its internal model-call count, clipboard restoration or ASR key support.
- **Superwhisper**: [official product page](https://superwhisper.com/) describes offline capability, local/cloud model options, custom modes and 100+ languages. The same page lists bringing your own AI API keys under Pro; the graphic says “BYOK in Pro,” not that every type of key works with every model. It also offers free-tier features.
- **Apple Dictation**: [official Mac guide](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac) describes built-in dictation, insertion into text fields and custom shortcuts. The graphic does not make a language-specific offline guarantee.
- **Measurements**: [immutable raw results](../../benchmarks/results/2026-10-24-doubao-synthetic.json), [method](../../benchmarks/README.md) and [report](../../benchmarks/RESULTS.md). All bar widths and displayed timing/error values are generated from that JSON, not manually estimated.

Product descriptions checked **2026-10-24**. The comparison is a qualitative capability map: arrows connect described capabilities and are **not** network topology, call counts, latency estimates or a score. Highlighting VoxType identifies this project rather than implying superiority on every axis. Other products' offline/multilanguage advantages and free tiers remain visible. There are no invented competitor measurements or radar ratings.

## Generate

```bash
# Python standard library only: write six editable SVGs and validate their XML.
python3 Scripts/render-readme-charts.py

# Optional: also export 2x PNGs using Pillow and existing macOS Arial fonts.
python3 Scripts/render-readme-charts.py --png
```

The optional PNG path checks text against canvas bounds. It does not install packages or copy font files. SVG remains the primary README format; PNG is a sharing/export companion. Font rendering can vary by viewer.

## 中文说明

优势图展示本项目可核实的实现；竞品图展示官方功能路线，不给产品编造分数。商业产品的免费档、离线和语言能力没有被隐藏。实测柱形长度直接来自原始 JSON；合成语音结果不能作为真人总体准确率或竞品胜出结论。SVG 和 PNG 都可重新生成，且不会增加应用运行依赖。
