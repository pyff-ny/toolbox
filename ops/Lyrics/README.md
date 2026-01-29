README.md

# 转换音频文件格式， 比如转成 wav

## 1. 普通转换 （保留原采样率/声道）
```bash
ffmpeg -i "input.m4a" "output.wav"
```
## 2. 适配whisper/语音识别（推荐：16khz + 单声道）
```bash
ffmpeg -y -i "/Users/jiali/Music/Music/Faded.m4a"  -ar 16000 -ac 1 /$HOME/Music/歌词提取/clip.wav
```
-ar 16000：采样率 16k（ASR 常用）
-ac 1：单声道（更稳定，文件更小）
-y：覆盖已有输出文件（避免询问）

## 3. 带有日文路径的写法（直接可用）
##歌曲名后的双引号前不要有空格，否则会产生 找不到文件的错误
```bash
ffmpeg -y -i "/Users/jiali/Music/BillyEastonミッドナイト・レター/ガールフレンドは午前2時.m4a" \
  -ar 16000 -ac 1 "/tmp/clip.wav"
```
## 4. 如果只想转换某一段（切片+转wav）
例如0:03 到0:27（24秒）
```bash
ffmpeg -y -i "input.m4a" -ss 00:00:03 -t 00:00:24 -ar 16000 -ac 1 /tmp/clip.wav
```


 
# 然后开始提取歌词
```bash
/opt/homebrew/Cellar/whisper-cpp/1.8.3/bin/whisper-cli \
  -l en \
  -m /opt/homebrew/share/whisper-cpp/models/ggml-small.bin \
  -f "$HOME/Music/歌词提取/clip.wav" \
  1> "$HOME/Music/歌词提取/lyrics_en.srt.txt" \
  2> "$HOME/Music/歌词提取/whisper_en.log"
```

## 清洗歌词
已经产生的输出，怎么快速“清洗”掉 timings（1 行命令）
如果你当前的歌词和 timings 混在同一个文件里（例如 /tmp/base.txt），用这条过滤
```bash
grep -vE '^(whisper_print_timings:|ggml_|\\^C|$)' /tmp/base.txt > /tmp/lyrics_clean.txt
```
你会得到一个干净版：/tmp/lyrics_clean.txt。

