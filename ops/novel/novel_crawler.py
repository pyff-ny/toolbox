#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Novel Crawler v6 (final)
- Robust TOC parsing for 3/4-digit chapter html links (supports relative paths)
- Polite fetch: retries, backoff, timeout, random sleep
- Optional robots.txt respect (default ON), with --ignore-robots to override
- Resume: skip existing chapter files by default (use --force to overwrite)
- Clean navigation noise ("上一页/下一页/本书目录/第一～四集..." etc.)
- Optional merge into one Markdown and generate EPUB via pandoc
- Interactive mode when no CLI args are given

Example:
  novel_crawler "https://www.bidutuijian.com/books/yztpingsanguo/000.html" \
    --out "./out_book" --start 1 --end 20 --merge "易中天品三国.md" --epub

Notes:
- If pandoc is not installed, EPUB generation will be skipped with a warning.
"""

from __future__ import annotations

import argparse
import os
import random
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple
from urllib.parse import urljoin, urlparse
from urllib import robotparser

import requests
from bs4 import BeautifulSoup


DEFAULT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/121.0.0.0 Safari/537.36"
)

# 章节链接：3~4 位数字结尾，支持相对路径 books/xxx/0001.html
CHAPTER_HREF_RE = re.compile(r"(?:^|/)(\d{3,4})\.html?$", re.IGNORECASE)

# 文件名清理
FILENAME_BAD_CHARS = re.compile(r'[\\/:*?"<>|]+')


# ----------------------------- Data model -----------------------------
@dataclass
class Chapter:
    index: int        # 1-based sequential index in output
    num: int          # numeric chapter id parsed from URL (for sorting)
    title: str
    url: str


# ----------------------------- Utilities -----------------------------
def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def sanitize_filename(name: str, max_len: int = 120) -> str:
    name = name.strip()
    name = FILENAME_BAD_CHARS.sub("_", name)
    name = re.sub(r"\s+", " ", name).strip()
    if len(name) > max_len:
        name = name[:max_len].rstrip()
    return name or "untitled"


def polite_sleep(min_s: float, max_s: float) -> None:
    time.sleep(random.uniform(min_s, max_s))


def fetch_html(
    session: requests.Session,
    url: str,
    *,
    timeout: int = 20,
    retries: int = 3,
    backoff: float = 0.8,
) -> str:
    last_err: Optional[Exception] = None
    for attempt in range(1, retries + 1):
        try:
            resp = session.get(url, timeout=timeout)
            resp.raise_for_status()
            # 自动检测编码
            if not resp.encoding or resp.encoding.lower() == "iso-8859-1":
                resp.encoding = resp.apparent_encoding or "utf-8"
            return resp.text
        except Exception as e:
            last_err = e
            if attempt < retries:
                sleep_s = backoff * attempt + random.uniform(0, 0.6)
                time.sleep(sleep_s)
    raise RuntimeError(f"Fetch failed: {url} (err={last_err})")


def robots_allowed(session: requests.Session, url: str, user_agent: str = DEFAULT_UA) -> bool:
    """
    读取 robots.txt 并判断是否允许抓取该 URL。
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
        return True


def make_soup(html: str) -> BeautifulSoup:
    # 尽量用 lxml（更快更宽容），没有就回落 html.parser
    try:
        return BeautifulSoup(html, "lxml")  # type: ignore[arg-type]
    except Exception:
        return BeautifulSoup(html, "html.parser")


# ----------------------------- TOC parsing -----------------------------
def extract_chapters_from_toc(toc_html: str, toc_url: str) -> List[Chapter]:
    """
    解析目录页，提取章节链接，去重、排序、过滤噪声。
    """
    soup = make_soup(toc_html)

    candidates: List[Tuple[int, str, str]] = []  # (num, abs_url, title)

    for a in soup.find_all("a", href=True):
        href = (a.get("href") or "").strip()
        if not href:
            continue
        if href.startswith("#") or href.lower().startswith("javascript:"):
            continue

        m = CHAPTER_HREF_RE.search(href)
        if not m:
            continue

        chap_no = int(m.group(1))
        abs_url = urljoin(toc_url, href)
        title = a.get_text(" ", strip=True) or f"第{chap_no}章"

        # 过滤明显非章节导航
        bad_words = ["首页", "目录", "章节列表", "返回", "上一页", "下一页", "加入书签", "收藏"]
        if any(w in title for w in bad_words) and (("上一页" in title) or ("下一页" in title) or ("目录" in title)):
            continue

        candidates.append((chap_no, abs_url, title))

    if not candidates:
        return []

    # 去重：同章号多次出现时，优先标题更长的
    best: Dict[int, Tuple[str, str]] = {}
    for chap_no, abs_url, title in candidates:
        if chap_no not in best:
            best[chap_no] = (abs_url, title)
        else:
            old_url, old_title = best[chap_no]
            if len(title) > len(old_title):
                best[chap_no] = (abs_url, title)
            else:
                best[chap_no] = (old_url, old_title)

    # 排序：按章号升序；输出 index 从 1..N
    out: List[Chapter] = []
    for idx, chap_no in enumerate(sorted(best.keys()), start=1):
        url, title = best[chap_no]
        out.append(Chapter(index=idx, num=chap_no, title=title, url=url))

    return out


# ----------------------------- Content extraction -----------------------------
NAV_NOISE_PATTERNS = [
    r"^上一页$",
    r"^下一页$",
    r"^本书目录$",
    r"^目录$",
    r"^章节列表$",
    r"^返回目录$",
    r"^返回书页$",
    r"^加入书签$",
    r"^收藏本站$",
    r"^推荐.*$",
    # “第一～四集 ... 上一页 本书目录 下一页”
    r"^第[一二三四五六七八九十百千]+[～\-~—]第[一二三四五六七八九十百千]+集.*$",
]


def choose_main_text_block(soup: BeautifulSoup) -> str:
    """
    选择正文块：优先常见 content 容器，否则选“最长文本块”。
    """
    # 移除脚本/样式
    for tag in soup(["script", "style", "noscript"]):
        tag.decompose()

    # 1) 先尝试常见容器
    for key, val in [
        ("id", "content"),
        ("id", "Content"),
        ("id", "chaptercontent"),
        ("id", "ChapterContent"),
    ]:
        node = soup.find(**{key: val})
        if node:
            return node.get_text("\n", strip=True)

    for cls in ["content", "article", "chapter", "txt", "text", "read-content"]:
        node = soup.find(class_=cls)
        if node:
            return node.get_text("\n", strip=True)

    # 2) 兜底：找最大文本 div
    best_text = ""
    best_len = 0
    for div in soup.find_all(["div", "article", "section"]):
        txt = div.get_text("\n", strip=True)
        if len(txt) > best_len:
            best_len = len(txt)
            best_text = txt

    if best_text:
        return best_text

    # 3) 再兜底：body
    body = soup.body.get_text("\n", strip=True) if soup.body else soup.get_text("\n", strip=True)
    return body


def clean_text(raw: str) -> str:
    """
    过滤导航噪声 + 收敛空行。
    """
    # 标准化换行
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    lines = [ln.strip() for ln in raw.split("\n")]
    lines = [ln for ln in lines if ln]

    noise_res = [re.compile(p) for p in NAV_NOISE_PATTERNS]

    cleaned: List[str] = []
    for ln in lines:
        if not ln:
            continue

        # 规则1：正则命中则丢弃
        if any(r.match(ln) for r in noise_res):
            continue

        # 规则2：一行同时包含“上一页/下一页/本书目录” 的导航串
        if ("上一页" in ln and "下一页" in ln) or ("本书目录" in ln and "下一页" in ln):
            continue

        cleaned.append(ln)

    # 收敛空行：用双空行分段
    out = "\n\n".join(cleaned)
    out = re.sub(r"\n{3,}", "\n\n", out).strip()
    return out


def parse_chapter(html: str) -> Tuple[str, str]:
    """
    返回 (title, cleaned_text)
    """
    soup = make_soup(html)
    h1 = soup.find("h1")
    title = h1.get_text(strip=True) if h1 else "Untitled"
    raw = choose_main_text_block(soup)
    text = clean_text(raw)

    # 避免正文第一行重复标题
    if text.startswith(title):
        text = text[len(title):].lstrip()

    return title, text


# ----------------------------- Output -----------------------------
def write_chapter_md(out_dir: str, chapter: Chapter, text: str, title: str) -> str:
    ensure_dir(out_dir)
    safe_title = sanitize_filename(title)
    filename = f"{chapter.index:03d} {safe_title}.md"
    path = os.path.join(out_dir, filename)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# {title}\n\n")
        f.write(text.strip())
        f.write("\n")
    return path


def merge_markdown(out_dir: str, merge_name: str, book_title: Optional[str] = None) -> str:
    ensure_dir(out_dir)

    if not merge_name.lower().endswith(".md"):
        merge_name += ".md"

    merge_path = os.path.join(out_dir, merge_name)

    # 按文件名前缀排序（001 xxx.md）
    files = [fn for fn in os.listdir(out_dir) if fn.lower().endswith(".md")]
    files = [fn for fn in files if fn != merge_name]
    files.sort()

    if not files:
        raise RuntimeError(f"No chapter md files found in: {out_dir}")

    if book_title is None:
        book_title = os.path.splitext(os.path.basename(merge_name))[0]

    with open(merge_path, "w", encoding="utf-8") as w:
        w.write(f"# {book_title}\n\n")
        for fn in files:
            p = os.path.join(out_dir, fn)
            with open(p, "r", encoding="utf-8", errors="ignore") as r:
                content = r.read().strip()
            # 去掉每章文件里的一级标题（# xxx），避免在合并文件里重复
            content = re.sub(r"^\s*#\s+.+?\n+", "", content, flags=re.M)
            w.write(f"## {os.path.splitext(fn)[0]}\n\n")
            w.write(content)
            w.write("\n\n")
    return merge_path


def pandoc_epub(md_path: str, epub_path: str, title: str, lang: str = "zh-CN") -> bool:
    """
    通过 pandoc 把 md 转成 epub
    """
    try:
        subprocess.run(
            [
                "pandoc",
                md_path,
                "-o",
                epub_path,
                "--from",
                "markdown",
                "--to",
                "epub",
                "--metadata",
                f"title={title}",
                "--metadata",
                f"lang={lang}",
                "--quiet",
            ],
            check=True,
        )
        return True
    except FileNotFoundError:
        print("[WARN] pandoc not found. Skip EPUB generation.")
        return False
    except subprocess.CalledProcessError as e:
        print(f"[WARN] pandoc failed (skip epub): {e}")
        return False


# ----------------------------- Interactive -----------------------------
def prompt(msg: str, default: str = "") -> str:
    if default:
        s = input(f"{msg} [default: {default}]: ").strip()
        return s if s else default
    return input(f"{msg}: ").strip()


def interactive_args() -> argparse.Namespace:
    print("== Novel Crawler ==")
    toc_url = prompt("TOC URL", "https://www.bidutuijian.com/books/yztpingsanguo/000.html")
    out_dir = prompt("Output dir", "./out_book")

    merge = prompt("Merge filename (blank=skip)", "")
    epub = "n"
    if merge:
        epub = prompt("Generate EPUB after merge? (y/N)", "N")

    start = prompt("Start chapter index", "1")
    end = prompt("End chapter index", "999999")

    ns = argparse.Namespace(
        toc_url=toc_url,
        out=out_dir,
        start=int(start),
        end=int(end),
        min_sleep=0.8,
        max_sleep=1.5,
        timeout=20,
        merge=merge,
        epub=(epub.lower().startswith("y")),
        title="",
        ignore_robots=False,
        force=False,
    )
    return ns


# ----------------------------- Main -----------------------------
def build_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({"User-Agent": DEFAULT_UA})
    return s


def run(ns: argparse.Namespace) -> None:
    out_dir = ns.out
    ensure_dir(out_dir)

    session = build_session()

    # robots 校验（只校验 toc_url）
    if not ns.ignore_robots:
        allowed = robots_allowed(session, ns.toc_url)
        if not allowed:
            raise RuntimeError(
                "robots.txt disallows crawling this URL. "
                "If you have permission, rerun with --ignore-robots."
            )

    toc_html = fetch_html(session, ns.toc_url, timeout=ns.timeout)
    chapters = extract_chapters_from_toc(toc_html, ns.toc_url)

    if not chapters:
        raise RuntimeError("Cannot parse any chapter links from TOC.")

    # 章节范围过滤（按目录顺序 index）
    start = max(1, ns.start)
    end = min(ns.end, len(chapters))
    selected = [c for c in chapters if start <= c.index <= end]

    print(f"[INFO] 解析到章节数: {len(chapters)}, 本次抓取: {len(selected)} ({start}..{end})")

    for chap in selected:
        # 输出路径：如果已存在且未 force，则跳过（断点续抓）
        safe_title = sanitize_filename(chap.title)
        filename = f"{chap.index:03d} {safe_title}.md"
        out_path = os.path.join(out_dir, filename)
        if (not ns.force) and os.path.exists(out_path):
            print(f"[SKIP] {chap.index:03d} {chap.title} (exists)")
            continue

        print(f"[抓取] {chap.index:03d} {chap.title} -> {chap.url}")
        html = fetch_html(session, chap.url, timeout=ns.timeout)
        title, text = parse_chapter(html)

        # 如果章节页的 h1 为空或默认 Untitled，则用目录标题兜底
        if not title or title == "Untitled":
            title = chap.title

        write_chapter_md(out_dir, chap, text, title)
        polite_sleep(ns.min_sleep, ns.max_sleep)

    merged_md = ""
    if ns.merge:
        merged_md = merge_markdown(out_dir, ns.merge, book_title=ns.title or None)
        print(f"[完成] 已合并: {merged_md}")

        if ns.epub:
            epub_path = os.path.splitext(merged_md)[0] + ".epub"
            book_title = ns.title or os.path.splitext(os.path.basename(merged_md))[0]
            ok = pandoc_epub(merged_md, epub_path, title=book_title)
            if ok:
                print(f"[完成] EPUB 已生成: {epub_path}")

    print("[完成] 所有任务结束。")


def main() -> None:
    if len(sys.argv) == 1:
        ns = interactive_args()
        run(ns)
        return

    ap = argparse.ArgumentParser()
    ap.add_argument("toc_url", help="目录页 URL（通常是 000.html）")
    ap.add_argument("--out", default="./out_book", help="输出目录")
    ap.add_argument("--start", type=int, default=1, help="从第几章开始（按目录顺序，从1计数）")
    ap.add_argument("--end", type=int, default=10**9, help="到第几章结束（含）")
    ap.add_argument("--min-sleep", type=float, default=0.8, help="每章最小延迟秒")
    ap.add_argument("--max-sleep", type=float, default=1.5, help="每章最大延迟秒")
    ap.add_argument("--timeout", type=int, default=20, help="请求超时秒")
    ap.add_argument("--merge", default="", help="合并输出单文件名（如 '全书.md'），留空则不合并")
    ap.add_argument("--epub", action="store_true", help="合并后生成 epub（依赖 pandoc）")
    ap.add_argument("--title", default="", help="书名（用于合并标题 & epub metadata），留空则用 merge 文件名")
    ap.add_argument("--ignore-robots", action="store_true", help="忽略 robots.txt（不推荐）")
    ap.add_argument("--force", action="store_true", help="覆盖已存在章节文件（默认跳过用于断点续抓）")

    ns = ap.parse_args()
    run(ns)


if __name__ == "__main__":
    main()
