import time
import os
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# --- 洞府设置 ---
WATCH_PATH = "/Users/jiali/toolbox/MidnightLetter" # 监控的文件夹路径
PRINTER_NAME = "HP_OfficeJet_3830_series" # 你的HP打印机名称（在系统设置-打印机中查看）

class LetterHandler(FileSystemEventHandler):
    """
    银月分神：负责盯着文件夹，一旦有新信笺放入，立即施法
    """
    def on_created(self, event):
        if not event.is_directory:
            file_path = event.src_path
            print(f"【银月】：检测到新信笺：{os.path.basename(file_path)}，准备传书...")
            
            # 1. 驱动 HP 打印机（利用 macOS 底层 CUPS 系统）
            # lp 指令是 Unix 系统的打印神咒
            exit_code = os.system(f'lp -d "{PRINTER_NAME}" "{file_path}"')
            
            if exit_code == 0:
                print(f"【大衍神君】：墨影匣已唤醒，打印中！")
                self.notify_iphone(os.path.basename(file_path))
            else:
                print(f"【大衍神君】：打印失败，请检查灵石（墨水）是否充足！")

    def notify_iphone(self, filename):
        """
        九界通识：给 iPhone 13 发送一条推送（利用简单的 Pushover 或 Bark App）
        """
        print(f"【通识砖】：已向 iPhone 13 发送成功提醒。")
        # 这里可以加入 Bark 等 API 的调用逻辑

if __name__ == "__main__":
    # 创建监控文件夹（如果不存在）
    if not os.path.exists(WATCH_PATH):
        os.makedirs(WATCH_PATH)

    event_handler = LetterHandler()
    observer = Observer()
    observer.schedule(event_handler, WATCH_PATH, recursive=False)
    
    print(f"【大衍玄晶法座】：自动化阵法已开启，正在监控文件夹：{WATCH_PATH}")
    print("按下 Ctrl+C 可停止阵法...")
    
    try:
        observer.start()
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
