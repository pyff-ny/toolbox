#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
novel_crawler.py
- 从 bidutuijian.com 的“目录页(000.html)”解析章节链接
- 逐章抓取正文，保存为 Markdown
- 可选：合并成一本 Markdown
- 断点续抓：已存在的章节文件默认跳过
- 友好抓取：限速、重试、robots.txt 检查（默认遵守，可 --ignore-robots 关闭）

用法示例：
  python3 novel_crawler.py "https://www.bidutuijian.com/books/yztpingsanguo/000.html"

  # 指定输出目录与合并文件名
  python3 novel_crawler.py "https://www.bidutuijian.com/books/yztpingsanguo/000.html" \
      --out "./yztpingsanguo" --merge "易中天品三国.md" --epub

  # 只抓第 10~20 章（按目录顺序）
  python3 novel_crawler.py "https://www.bidutuijian.com/books/yztpingsanguo/000.html" \
      --start 10 --end 20

  # 若 robots.txt 不允许但你确认有权限抓取（不推荐）
  python3 novel_crawler.py "https://www.bidutuijian.com/books/yztpingsanguo/000.html" --ignore-robots
"""

from __future__ import annotations

import argparse
import os
import random
import re
import sys
import time
import subprocess
from dataclasses import dataclass
from typing import List, Optional, Tuple
from urllib.parse import urljoin, urlparse
from urllib import robotparser

import requests
from bs4 import BeautifulSoup

DEFAULT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0 Safari/537.36"
)

NAV_NOISE_PATTERNS = [
    r"^\s*必读推荐\s*$",
    r"^\s*第一页\s*[:：]?\s*$",
    r"^\s*本书目录\s*$",
    r"^\s*下一页\s*$",
    r"^\s*上一页\s*$",
    r"^\s*返回目录\s*$",
    r"^\s*目录\s*$",
]

CHAPTER_URL_RE = re.compile(r"/books/[^/]+/\d+\.html$", re.IGNORECASE)


@dataclass
class Chapter:
    idx: int
    title: str
    url: str


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def polite_sleep(min_s: float, max_s: float) -> None:
    time.sleep(random.uniform(min_s, max_s))


def make_session(timeout: int = 20) -> requests.Session:
    s = requests.Session()
    s.headers.update({
        "User-Agent": DEFAULT_UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
        "Connection": "keep-alive",
    })
    s.request = _wrap_request_with_timeout(s.request, timeout)  # type: ignore
    return s


def _wrap_request_with_timeout(req_func, timeout: int):
    def wrapper(method, url, **kwargs):
        if "timeout" not in kwargs:
            kwargs["timeout"] = timeout
        return req_func(method, url, **kwargs)
    return wrapper


def fetch_html(session: requests.Session, url: str, retries: int = 4) -> str:
    backoff = 1.2
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            resp = session.get(url, allow_redirects=True)
            resp.raise_for_status()

            # 尽量用网站声明编码；否则使用 apparent_encoding
            if not resp.encoding or resp.encoding.lower() == "iso-8859-1":
                resp.encoding = resp.apparent_encoding or "utf-8"
            return resp.text
        except Exception as e:
            last_err = e
            if attempt < retries:
                sleep_s = backoff * attempt + random.uniform(0, 0.6)
                time.sleep(sleep_s)
            else:
                break
    raise RuntimeError(f"Fetch failed: {url} (err={last_err})")


def robots_allowed(session: requests.Session, url: str, user_agent: str = DEFAULT_UA) -> bool:
    """
    运行时读取 robots.txt 并判断是否允许抓取该 URL。
    注意：并非所有站点都有 robots.txt；无则视为允许。
    """
    parsed = urlparse(url)
    robots_url = f"{parsed.scheme}://{parsed.netloc}/robots.txt"
    rp = robotparser.RobotFileParser()
    try:
        txt = fetch_html(session, robots_url, retries=2)
        rp.parse(txt.splitlines())
        return rp.can_fetch(user_agent, url)
    except Exception:
        # 抓不到 robots.txt：保守起见当作允许，但你也可以改成 False 更严格
        return True


def extract_links_from_toc(toc_html: str, toc_url: str) -> List[Chapter]:
    soup = BeautifulSoup(toc_html, "lxml")

    links: List[Tuple[str, str]] = []
    for a in soup.find_all("a", href=True):
        href = a["href"].strip()
        abs_url = urljoin(toc_url, href)
        # 只保留章节页（000/001/002... 这种）
        if CHAPTER_URL_RE.search(urlparse(abs_url).path):
            title = a.get_text(strip=True)
            links.append((title, abs_url))

    # 去重（按 URL）
    seen = set()
    uniq = []
    for title, u in links:
        if u not in seen:
            seen.add(u)
            uniq.append((title, u))

    # 通常目录里除了章节，还有“必读推荐/关于”等，过滤掉明显非章节的
    # 经验：章节标题往往含“讲”或“第”
    filtered = []
    for title, u in uniq:
        if ("讲" in title) or (title.startswith("第")):
            filtered.append((title, u))

    chapters = [Chapter(idx=i + 1, title=t, url=u) for i, (t, u) in enumerate(filtered)]
    return chapters


def choose_main_text_block(soup: BeautifulSoup) -> str:
    # 移除脚本/样式
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()

    candidates = []
    selectors = [
        "main", "article",
        "div#content", "div.content", "div#chaptercontent", "div#BookText",
        "div.text", "div.page-content", "div.container",
        "body",
    ]

    for sel in selectors:
        for node in soup.select(sel):
            txt = node.get_text("\n", strip=True)
            if txt:
                candidates.append(txt)

    if not candidates:
        return soup.get_text("\n", strip=True)

    # 取“最长”的块作为正文候选
    candidates.sort(key=len, reverse=True)
    return candidates[0]


def clean_text(raw: str) -> str:
    lines = [ln.strip() for ln in raw.splitlines()]
    cleaned = []
    noise_res = [re.compile(p) for p in NAV_NOISE_PATTERNS]

    for ln in lines:
        if not ln:
            continue
        # 去掉导航噪声行
        if any(r.match(ln) for r in noise_res):
            continue
        # 去掉类似“第一页 : 本书目录 : 下一页”这种一行导航
        if ("本书目录" in ln and "下一页" in ln) or ("第一页" in ln and "下一页" in ln):
            continue
        cleaned.append(ln)

    # 合并连续重复空白已处理；保留段落间空行
    out = "\n\n".join(cleaned)
    # 收敛多余空行
    out = re.sub(r"\n{3,}", "\n\n", out).strip()
    return out


def parse_chapter(html: str) -> Tuple[str, str]:
    soup = BeautifulSoup(html, "lxml")
    h1 = soup.find("h1")
    title = h1.get_text(strip=True) if h1 else "Untitled"

    raw = choose_main_text_block(soup)
    text = clean_text(raw)

    # 有时“最长块”会把标题也包含进去：避免重复
    if text.startswith(title):
        text = text[len(title):].lstrip()
    return title, text


def safe_filename(name: str) -> str:
    # 兼容 macOS / Windows
    name = re.sub(r"[\/\\\:\*\?\"\<\>\|]", "_", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name


def write_markdown(path: str, title: str, body: str, source_url: str) -> None:
    md = f"# {title}\n\n来源：{source_url}\n\n{body}\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(md)


def merge_markdown(chapters: List[Chapter], out_dir: str, merge_name: str) -> str:
    merged_path = os.path.join(out_dir, merge_name)
    with open(merged_path, "w", encoding="utf-8") as w:
        w.write(f"# {os.path.splitext(merge_name)[0]}\n\n")
        for ch in chapters:
            # 章节文件名策略：按序号
            fn = os.path.join(out_dir, f"{ch.idx:03d}.md")
            if not os.path.exists(fn):
                continue
            with open(fn, "r", encoding="utf-8") as r:
                content = r.read().strip()
            w.write("\n\n---\n\n")
            w.write(content)
            w.write("\n")
    return merged_path



def md_to_epub(md_path: str, epub_path: str, title: str, author: str = "", lang: str = "zh-CN") -> None:
    """Convert a merged Markdown file to EPUB using pandoc."""
    cmd = [
        "pandoc",
        md_path,
        "-o",
        epub_path,
        "--toc",
        "--metadata",
        f"title={title}",
        "--metadata",
        f"lang={lang}",
    ]
    if author.strip():
        cmd += ["--metadata", f"author={author.strip()}"]

    try:
        subprocess.run(cmd, check=True)
    except FileNotFoundError:
        raise RuntimeError("未找到 pandoc：请先安装 pandoc（macOS 可用 brew install pandoc）")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"pandoc 转换失败：{e}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("toc_url", help="目录页 URL（通常是 000.html）")
    ap.add_argument("--out", default="./out_book", help="输出目录")
    ap.add_argument("--start", type=int, default=1, help="从第几章开始（按目录顺序，从1计数）")
    ap.add_argument("--end", type=int, default=10**9, help="到第几章结束（含）")
    ap.add_argument("--min-sleep", type=float, default=0.8, help="每章最小延迟秒")
    ap.add_argument("--max-sleep", type=float, default=1.5, help="每章最大延迟秒")
    ap.add_argument("--timeout", type=int, default=20, help="请求超时秒")
    ap.add_argument("--merge", default="", help="合并输出单文件名（如 '全书.md'），留空则不合并")
    ap.add_argument("--epub", action="store_true", help="在合并生成 MD 后，自动生成 EPUB（需要 pandoc）")
    ap.add_argument("--epub-name", default="", help="EPUB 输出文件名（默认与合并 MD 同名，仅后缀不同）")
    ap.add_argument("--title", default="", help="书名（默认使用合并文件名的去后缀部分）")
    ap.add_argument("--author", default="", help="作者（可选，用于 EPUB metadata）")
    ap.add_argument("--lang", default="zh-CN", help="语言标识（默认 zh-CN，用于 EPUB metadata）")
    ap.add_argument("--ignore-robots", action="store_true", help="忽略 robots.txt（不推荐）")
    args = ap.parse_args()

    ensure_dir(args.out)
    session = make_session(timeout=args.timeout)

    # robots 检查（对目录页即可）
    if not args.ignore_robots:
        allowed = robots_allowed(session, args.toc_url)
        if not allowed:
            print("robots.txt 似乎不允许抓取该页面。若你确认有权限，可加 --ignore-robots。", file=sys.stderr)
            sys.exit(2)

    toc_html = fetch_html(session, args.toc_url)
    chapters = extract_links_from_toc(toc_html, args.toc_url)
    if not chapters:
        print("未能从目录页解析到章节链接。你可以把目录页 HTML 保存后发我，我帮你精确适配。", file=sys.stderr)
        sys.exit(1)

    # 选取范围
    start = max(1, args.start)
    end = min(len(chapters), args.end)
    selected = [ch for ch in chapters if start <= ch.idx <= end]

    print(f"解析到章节数：{len(chapters)}，本次抓取：{len(selected)}（{start}..{end}）")

    for ch in selected:
        out_path = os.path.join(args.out, f"{ch.idx:03d}.md")
        if os.path.exists(out_path):
            print(f"[跳过] {ch.idx:03d} 已存在：{out_path}")
            continue

        if not args.ignore_robots:
            if not robots_allowed(session, ch.url):
                print(f"[跳过] robots.txt 不允许：{ch.url}")
                continue

        print(f"[抓取] {ch.idx:03d} {ch.title} -> {ch.url}")
        html = fetch_html(session, ch.url)
        title, body = parse_chapter(html)

        # 文件名按序号存储；标题写入 md 内
        write_markdown(out_path, title=title, body=body, source_url=ch.url)

        polite_sleep(args.min_sleep, args.max_sleep)

    if args.merge:
        merged_path = merge_markdown(selected, args.out, args.merge)
        print(f"[完成] 已合并：{merged_path}")

        # 可选：生成 EPUB
        if args.epub:
            title = args.title.strip() or os.path.splitext(os.path.basename(merged_path))[0]
            epub_name = args.epub_name.strip()
            epub_path = os.path.join(args.out, epub_name) if epub_name else os.path.splitext(merged_path)[0] + ".epub"
            try:
                md_to_epub(merged_path, epub_path, title=title, author=args.author, lang=args.lang)
                print(f"[完成] EPUB 已生成：{epub_path}")
            except Exception as e:
                print(f"[错误] EPUB 生成失败：{e}", file=sys.stderr)

    print("[完成] 所有任务结束。")


if __name__ == "__main__":
    main()

# 用法示例：
#python3 novel_crawler.py "https://www.bidutuijian.com/books/yztpingsanguo/000.html" \
#--out "./yztpingsanguo" \
#--merge "易中天品三国.md"
#--start 10 --end 20
#--ignore-robots

# End of novel_crawler.py


