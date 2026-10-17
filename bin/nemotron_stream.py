#!/Users/user/venvs/mlx-latest/bin/python
"""本地補丁：Nemotron-3.5-ASR-streaming-0.6B 橋接器（mlx-audio，跑在 mlx-latest venv）。

兩種模式：
1. 串流（預設）：stdin 讀 s16le/16k/mono PCM，stdout 每行一個 JSON：
   {"ready": true}            模型載入完成
   {"delta": "text"}          增量文字（append-only，RNNT 定稿不再回頭改）
   {"eof": true}              輸入結束
2. --file PATH：整檔轉錄，輸出一行 {"text": "..."} 後結束（離線/競技場用）。

參數：
  --lang      語言碼（en-US / zh-TW / zh-CN / ja-JP / auto，預設 auto）
  --delay-ms  串流 look-ahead（80/160/560/1120，預設 560＝準確率與延遲平衡）
"""
import argparse
import json
import os
import sys

# 模型已在本地 HF cache：離線模式避免載入時對 hub 的連線檢查卡死
# （本機網路對 HF 不穩，線上 etag 檢查曾掛住數分鐘）
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

MODEL_ID = os.environ.get(
    "NEMOTRON_RT_MODEL", "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit")
# 300ms 大塊饋入：100ms 小塊會讓 RNNT 每秒 10 次小推論，與並行的翻譯
# server 搶 GPU 時間切片（實測翻譯延遲 2-3×）；300ms 對延遲影響 ≤0.2s
CHUNK_SAMPLES = 4800  # 300ms @ 16kHz


def _emit(obj, out):
    out.write(json.dumps(obj, ensure_ascii=False) + "\n")
    out.flush()


def run_stream(args, out):
    import threading
    import time

    import numpy as np
    from mlx_audio.stt import load

    model = load(MODEL_ID)
    lang = None if args.lang in ("auto", "") else args.lang
    sess = model.create_streaming_session(
        language=lang, transcription_delay_ms=args.delay_ms)
    _emit({"ready": True, "sr": sess.input_sample_rate}, out)

    # 消費者執行緒：持續 step()（協議本意＝單一消費者驅動解碼）。
    # 教訓：每餵一塊才 step 一次在密集語音＋GPU 競爭下消化不及，
    # 佇列 >30s 直接 BufferError 崩潰（2026-10-17 實境秀多人重疊語音炸過）
    def _consumer():
        while not sess.done:
            try:
                for delta in sess.step(max_decode_tokens=8):
                    if delta:
                        _emit({"delta": delta}, out)
            except Exception as e:  # 解碼異常不無聲死掉，回報後結束
                _emit({"error": str(e)}, out)
                return
            time.sleep(0.02)

    consumer_t = threading.Thread(target=_consumer, daemon=True)
    consumer_t.start()

    buf = b""
    stdin = sys.stdin.buffer
    while True:
        chunk = stdin.read(CHUNK_SAMPLES * 2)
        if not chunk:
            break
        buf += chunk
        while len(buf) >= CHUNK_SAMPLES * 2:
            pcm = np.frombuffer(buf[:CHUNK_SAMPLES * 2], dtype=np.int16)
            buf = buf[CHUNK_SAMPLES * 2:]
            try:
                sess.feed(pcm.astype(np.float32) / 32768.0)
            except BufferError as e:
                _emit({"error": f"feed overflow: {e}"}, out)
                return
    sess.close()
    deadline = time.monotonic() + 30
    while not sess.done and time.monotonic() < deadline:
        time.sleep(0.1)
    _emit({"eof": True}, out)


def run_file(args, out):
    from mlx_audio.stt import load

    model = load(MODEL_ID)
    lang = None if args.lang in ("auto", "") else args.lang
    r = model.generate(args.file, language=lang)
    _emit({"text": r.text}, out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", default="auto")
    ap.add_argument("--delay-ms", type=int,
                    default=int(os.environ.get("NEMOTRON_RT_DELAY", "560")))
    ap.add_argument("--file", default=None)
    args = ap.parse_args()
    out = sys.stdout
    if args.file:
        run_file(args, out)
    else:
        run_stream(args, out)


if __name__ == "__main__":
    main()
