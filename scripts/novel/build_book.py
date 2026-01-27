#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import re
import argparse
import subprocess

##=========用法=========
#运行方式（举例）：
#python3 build_book.py --in-dir "./yztpingsanguo" --title "易中天品三国"
#它会在当前目录生成：
#易中天品三国.md
#易中天品三国.epub
#
#
#
#
CHAPTER_RE = re.compile(r"^(\d+)\.md$", re.IGNORECASE)

def find_chapter_files(folder: str):
    items = []
    for fn in os.listdir(folder):
        m = CHAPTER_RE.match(fn)
        if m:
            idx = int(m.group(1))
            items.append((idx, os.path.join(folder, fn)))
    items.sort(key=lambda x: x[0])
    return items

def merge_md(chapters, out_md: str, book_title: str, drop_source_line: bool = True):
    with open(out_md, "w", encoding="utf-8") as w:
        w.write(f"# {book_title}\n\n")
        for idx, path in chapters:
            with open(path, "r", encoding="utf-8") as r:
                content = r.read().strip()

            # 可选：去掉每章的 “来源：xxx” 这行（更适合做 epub）
            if drop_source_line:
                content = re.sub(r"^来源：.*\n\n", "", content, flags=re.M)

            w.write("\n\n---\n\n")
            w.write(content)
            w.write("\n")

def md_to_epub(in_md: str, out_epub: str, book_title: str):
    cmd = [
        "pandoc",
        in_md,
        "-o", out_epub,
        "--toc",
        "--metadata", f"title={book_title}",
    ]
    subprocess.run(cmd, check=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in-dir", required=True, help="章节 md 所在目录（包含 001.md/002.md...）")
    ap.add_argument("--title", required=True, help="书名（用于 md 标题与 epub metadata）")
    ap.add_argument("--out-md", default="", help="合并后的 md 文件名（默认：书名.md）")
    ap.add_argument("--out-epub", default="", help="输出 epub 文件名（默认：书名.epub）")
    args = ap.parse_args()

    in_dir = args.in_dir
    book_title = args.title
    out_md = args.out_md or f"{book_title}.md"
    out_epub = args.out_epub or f"{book_title}.epub"

    chapters = find_chapter_files(in_dir)
    if not chapters:
        raise SystemExit(f"在 {in_dir} 未找到形如 001.md/002.md 的章节文件。")

    merge_md(chapters, out_md, book_title, drop_source_line=True)
    md_to_epub(out_md, out_epub, book_title)

    print("完成：")
    print(" -", os.path.abspath(out_md))
    print(" -", os.path.abspath(out_epub))

if __name__ == "__main__":
    main()
