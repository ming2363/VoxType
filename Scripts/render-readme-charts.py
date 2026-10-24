#!/usr/bin/env python3
"""Render bilingual, dependency-free SVGs from documented facts and measured results."""
from html import escape
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/images"
RESULT = ROOT / "benchmarks/results/2026-10-24-doubao-synthetic.json"
BLUE, INK, GRAY = "#2563eb", "#111827", "#64748b"


class Canvas:
    def __init__(self, height, title, description):
        self.lines = [f'<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="{height}" viewBox="0 0 1200 {height}" role="img" aria-labelledby="title desc">']
        self.lines.append(f'<title id="title">{escape(title)}</title>')
        self.lines.append(f'<desc id="desc">{escape(description)}</desc>')
        self.lines.append('<style>text{font-family:"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif}</style>')
        self.lines.append('<defs>')
        for name, color in [("blue", BLUE), ("gray", "#94a3b8")]:
            self.lines.append(f'<marker id="arrow-{name}" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto"><path d="M0 0L10 3.5L0 7Z" fill="{color}"/></marker>')
        self.lines.append('</defs>')
        self.rect(1, 1, 1198, height - 2, "#ffffff", "#e2e8f0", 28)

    def rect(self, x, y, width, height, fill, stroke="none", radius=12):
        self.lines.append(f'<rect x="{x}" y="{y}" width="{width}" height="{height}" rx="{radius}" fill="{fill}" stroke="{stroke}"/>')

    def text(self, x, y, value, size=20, color=INK, weight=400, anchor="start"):
        self.lines.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" font-weight="{weight}" text-anchor="{anchor}">{escape(str(value))}</text>')

    def line(self, x1, y1, x2, y2, color="#e2e8f0", arrow=None):
        marker = f' marker-end="url(#arrow-{arrow})"' if arrow else ""
        self.lines.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="2"{marker}/>')

    def save(self, name):
        self.lines.append('</svg>')
        target = OUT / name
        target.write_text("\n".join(self.lines) + "\n", encoding="utf-8")
        ET.parse(target)
        if "--png" in sys.argv:
            render_png(target)


def render_png(source):
    """Optional 2x PNG export with Pillow and macOS fonts; no browser or downloads."""
    from PIL import Image, ImageDraw, ImageFont

    root = ET.parse(source).getroot()
    scale = 2
    width, height = int(root.attrib["width"]), int(root.attrib["height"])
    image = Image.new("RGB", (width * scale, height * scale), "white")
    draw = ImageDraw.Draw(image)
    fonts = Path("/System/Library/Fonts/Supplemental")
    for node in root:
        tag = node.tag.rsplit("}", 1)[-1]
        a = node.attrib
        if tag == "rect":
            x, y, w, h = [float(a[k]) * scale for k in ["x", "y", "width", "height"]]
            stroke = a.get("stroke", "none")
            draw.rounded_rectangle((x, y, x + w, y + h), radius=float(a.get("rx", 0)) * scale,
                                   fill=a["fill"], outline=None if stroke == "none" else stroke, width=scale)
        elif tag == "line":
            x1, y1, x2, y2 = [float(a[k]) * scale for k in ["x1", "y1", "x2", "y2"]]
            draw.line((x1, y1, x2, y2), fill=a["stroke"], width=2 * scale)
            if "marker-end" in a:
                draw.polygon([(x2 - 16 * scale, y2 - 6 * scale), (x2 + scale, y2),
                              (x2 - 16 * scale, y2 + 6 * scale)], fill=a["stroke"])
        elif tag == "text":
            text = node.text or ""
            cjk = any(ord(char) >= 0x3000 for char in text)
            bold = int(a.get("font-weight", 400)) >= 600
            name = "Arial Unicode.ttf" if cjk else ("Arial Bold.ttf" if bold else "Arial.ttf")
            font = ImageFont.truetype(str(fonts / name), round(float(a["font-size"]) * scale))
            x, y = float(a["x"]) * scale, float(a["y"]) * scale
            if a.get("text-anchor") == "middle":
                x -= draw.textlength(text, font=font) / 2
            bounds = draw.textbbox((x, y), text, font=font, anchor="ls")
            assert bounds[0] >= 0 and bounds[2] <= width * scale, f"Text overflows {source.name}: {text}"
            assert bounds[1] >= 0 and bounds[3] <= height * scale
            draw.text((x, y), text, font=font, fill=a["fill"], anchor="ls",
                      stroke_width=1 if cjk and bold else 0)
    image.save(source.with_suffix(".png"), optimize=True)


def advantages(lang):
    zh = lang == "zh"
    title = "把语音输入的控制权交给你" if zh else "Your dictation. Your code. Your service account."
    c = Canvas(350, title, "VoxType implementation facts, not competitor scores. ASR usage is billed separately.")
    c.text(48, 62, title, 32, weight=700)
    c.text(48, 99, "原生 Swift · 自备 ASR Key · 按住说话，松开收尾" if zh else "Native Swift · Bring your ASR key · Hold to speak, release to finish", 20, GRAY)
    items = [
        ("Apache 2.0", "开源可改" if zh else "Open source", "源码可审查、可修改" if zh else "Inspect and modify the code"),
        ("$0", "客户端订阅费" if zh else "Client subscription", "ASR 用量另行计费" if zh else "ASR usage billed separately"),
        ("0", "随包本地模型" if zh else "Bundled local models", "云端流式识别" if zh else "Streaming cloud recognition"),
        ("0", "听写剪贴板写入" if zh else "Auto clipboard writes", "直接写入焦点输入框" if zh else "Direct field / Unicode input"),
    ]
    for i, (value, label, sub) in enumerate(items):
        x = 48 + i * 282
        c.rect(x, 133, 258, 156, "#eff6ff", "#dbeafe", 18)
        c.text(x + 20, 184, value, 32, BLUE, 700)
        c.text(x + 20, 225, label, 20, INK, 600)
        c.text(x + 20, 258, sub, 16, GRAY)
    c.text(48, 324, "剪贴板说明：仅主动点击「复制上次结果」会修改剪贴板。" if zh else "Clipboard changes only when you explicitly choose Copy Last Result.", 16, GRAY)
    c.save(f"advantages-{lang}.svg")


def comparison(lang):
    zh = lang == "zh"
    title = "四种语音输入路线，看清你需要哪一种" if zh else "Four dictation approaches. Different kinds of control."
    c = Canvas(770, title, "Qualitative product capability map based on official sources, checked 2026-10-24. No numeric ratings, latency ranking or inferred network topology.")
    c.text(48, 62, title, 32, weight=700)
    c.text(48, 99, "VoxType 的选择：代码可改、账号自管、听写保留剪贴板。" if zh else "VoxType: editable source, your ASR account, and a clipboard-free input path.", 20, GRAY)
    cards = [
        ("VoxType", "原生直接输入" if zh else "Native, direct dictation",
         ["自己的 Key", "流式 ASR", "焦点输入框"] if zh else ["Your key", "Streaming ASR", "Text field"],
         ["开源可改", "客户端免订阅", "不碰剪贴板"] if zh else ["Open source", "No client sub", "No clipboard"]),
        ("Wispr Flow", "跨平台语音写作" if zh else "Writing across platforms",
         ["说话", "润色与排版", "当前应用"] if zh else ["Speech", "Polish / format", "Current app"],
         ["100+ 语言", "跨平台", "免费 / Pro"] if zh else ["100+ languages", "Cross-platform", "Free / Pro"]),
        ("Superwhisper", "离线与模型选择" if zh else "Offline and model choice",
         ["本地 / 云模型", "自定义模式", "当前应用"] if zh else ["Local / cloud", "Custom modes", "Current app"],
         ["支持离线", "自带 Key 属 Pro", "100+ 语言"] if zh else ["Offline option", "BYOK in Pro", "100+ languages"]),
        ("Apple Dictation", "系统内置听写" if zh else "Built into macOS",
         ["系统快捷键", "系统听写", "焦点输入框"] if zh else ["System shortcut", "OS dictation", "Text field"],
         ["系统自带", "无需独立安装", "自定快捷键"] if zh else ["Built in", "No extra app", "Custom shortcut"]),
    ]
    for i, (product, sub, nodes, chips) in enumerate(cards):
        x, y = 48 + (i % 2) * 564, 135 + (i // 2) * 266
        own = i == 0
        color = BLUE if own else INK
        c.rect(x, y, 540, 238, "#eff6ff" if own else "#f8fafc", "#93c5fd" if own else "#e2e8f0", 20)
        c.text(x + 24, y + 42, product, 28, color, 700)
        c.text(x + 24, y + 73, sub, 19, GRAY)
        for n, label in enumerate(nodes):
            bx = x + 22 + n * 174
            c.rect(bx, y + 103, 148, 48, "#ffffff", "#bfdbfe" if own else "#cbd5e1", 12)
            c.text(bx + 74, y + 133, label, 17, color, 600, "middle")
            if n < 2:
                c.line(bx + 151, y + 127, bx + 170, y + 127, BLUE if own else "#94a3b8", "blue" if own else "gray")
        for n, chip in enumerate(chips):
            bx = x + 22 + n * 174
            c.rect(bx, y + 177, 148, 34, "#dbeafe" if own else "#e2e8f0", radius=17)
            c.text(bx + 74, y + 200, chip, 16, color, 600, "middle")
    c.rect(48, 685, 14, 14, BLUE, radius=4)
    c.text(72, 698, "本项目" if zh else "VoxType", 16, GRAY)
    c.rect(184, 685, 14, 14, "#94a3b8", radius=4)
    c.text(208, 698, "其他产品路线" if zh else "Other approaches", 16, GRAY)
    c.text(48, 737, "官方资料核对：2026-10-24。能力路线示意，不代表调用次数或性能排名；VoxType 当前需联网。" if zh else "Checked 2026-10-24. Capability map, not call counts or performance ranks. VoxType requires the network.", 16, GRAY)
    c.save(f"comparison-{lang}.svg")


def benchmark(lang, report):
    zh = lang == "zh"
    summary = report["summary"]
    c = Canvas(720, "VoxType 流式 ASR 实测" if zh else "VoxType streaming ASR: measured results",
               "Real Doubao calls; 30 synthetic sentences repeated twice. P50/P95 transport timings exclude microphone startup and UI insertion. No competitors were benchmarked.")
    c.text(48, 62, "VoxType 流式 ASR 实测" if zh else "VoxType streaming ASR: measured results", 32, weight=700)
    c.text(48, 99, "2026-10-24 · 30 条合成语音 × 2 · 真实接口调用" if zh else "2026-10-24 · 30 synthetic sentences × 2 · Real API calls", 19, GRAY)
    c.rect(924, 35, 228, 78, "#eff6ff", "#dbeafe", 16)
    c.text(1038, 69, f'{summary["successful"]} / {summary["requests"]}', 27, BLUE, 700, "middle")
    c.text(1038, 95, "请求成功" if zh else "successful requests", 16, GRAY, anchor="middle")
    c.rect(48, 128, 17, 12, BLUE, radius=3)
    c.text(75, 140, "P50", 17, GRAY)
    c.rect(152, 128, 17, 12, "#38bdf8", radius=3)
    c.text(179, 140, "P95", 17, GRAY)
    # A common zero-based millisecond axis; bar widths are calculated from raw results.
    origin, span, ceiling = 302, 750, 1500
    for tick in [0, 500, 1000, 1500]:
        x = origin + span * tick / ceiling
        c.line(x, 183, x, 410)
        c.text(x, 169, str(tick), 16, GRAY, anchor="middle")
    c.text(1095, 169, "毫秒" if zh else "ms", 16, GRAY)
    for i, (key, label, sub) in enumerate([
        ("first_text_ms", "首个文本" if zh else "First text", "握手后的音频时间线" if zh else "Post-handshake audio timeline"),
        ("final_tail_ms", "最终响应" if zh else "Final tail", "末包入队后的响应" if zh else "After final packet is queued"),
    ]):
        y = 203 + i * 117
        c.text(48, y + 17, label, 24, weight=600)
        c.text(48, y + 45, sub, 16, GRAY)
        for j, (percentile, color) in enumerate([("p50", BLUE), ("p95", "#38bdf8")]):
            value = summary[key][percentile]
            width = span * value / ceiling
            c.rect(origin, y + j * 33, width, 22, color, radius=6)
            c.text(origin + width + 13, y + j * 33 + 18, f"{value:,.0f}", 20, INK, 600)
    c.text(48, 457, "识别错误率 · 三种单位分别统计" if zh else "Recognition errors · different units, reported separately", 23, weight=600)
    for i, (category, label, unit) in enumerate([
        ("zh", "中文 CER" if zh else "Chinese CER", "字" if zh else "characters"),
        ("en", "英文 WER" if zh else "English WER", "词" if zh else "words"),
        ("mixed", "中英混合 MER" if zh else "Mixed MER", "混合单位" if zh else "mixed units"),
    ]):
        x, data = 48 + i * 376, summary[category]
        c.rect(x, 484, 352, 146, "#f8fafc", "#e2e8f0", 18)
        c.text(x + 22, 516, label, 19, GRAY)
        c.text(x + 22, 565, f'{data["error_rate_pct"]:.2f}%', 38, INK, 700)
        c.text(x + 22, 603, f'{data["edits"]} / {data["reference_units"]} {unit}', 17, GRAY)
    c.text(48, 672, "ASR 传输与归并实测；不含麦克风启动和输入框落字，不是竞品对比。" if zh else "ASR transport / reducer timings; exclude microphone startup and UI insertion. No competitor timing data.", 16, GRAY)
    c.text(48, 700, "合成语音重复样本不代表真人总体准确率；不同错误率单位不能直接横比。" if zh else "Repeated synthetic audio does not establish human-speech accuracy. CER / WER / MER use different units.", 16, GRAY)
    c.save(f"benchmark-{lang}.svg")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    measured = json.loads(RESULT.read_text())
    assert measured["summary"]["requests"] == len(measured["rows"])
    for language in ["en", "zh"]:
        advantages(language)
        comparison(language)
        benchmark(language, measured)
    print("Generated and XML-validated six bilingual SVG assets.")
