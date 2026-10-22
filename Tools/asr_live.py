"""Paced ASR diagnostic. Audio availability follows a monotonic clock.

Shared app-like policy: first prefix at 400 ms, then 1 s updates. Native calls
are serialized; a slow call coalesces new audio, never moves the release clock.
This measures runtime delivery, not UI, physical capture, cleanup or insertion.
"""
import array
import hashlib
import json
import os
from pathlib import Path
import resource
import select
import shutil
import time
import wave
from asr_benchmark import ROOT, words, error_rate


def fixture(language):
    path = ROOT / f"Tests/Fixtures/meetings/{language}-dialogue.wav"
    with wave.open(str(path)) as wav:
        samples = array.array("h", wav.readframes(wav.getnframes()))
    # First two complete sentences, including a quiet release margin. These
    # authored fixtures start speaking at sample zero; no microphone onset guess.
    seconds = 7.25 if language == "en" else 6.65
    audio = [v / 32768 for v in samples[:round(seconds * 16000)]]
    lines = (ROOT / f"Tests/Fixtures/meetings/scripts/{language}-dialogue.txt").read_text().splitlines()[:2]
    reference = " ".join(line.split(":", 1)[1].strip() for line in lines)
    return audio, reference, {"path": str(path.relative_to(ROOT)),
        "source_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "samples": len(audio), "seconds": seconds, "reference": reference}


def measure(infer, languages=("en", "fr"), reset=None, finish=None, trials=3):
    rows = []
    fixtures = {}
    # Warm each language and graph before the paced trials; separately retained.
    warmups = []
    for language in languages:
        audio, reference, identity = fixture(language)
        fixtures[language] = identity
        start = time.perf_counter()
        # Warm the short-prefix shapes too. A full-clip warmup alone would
        # leave a multifunction CoreML model's 1s graph cold on its first word.
        prefix = .4
        while prefix < len(audio)/16000:
            infer(audio[:round(prefix*16000)], language, False)
            prefix += 1
        infer(audio, language, True)
        if finish:
            finish(language)
        if reset:
            reset()
        warmups.append({"language": language, "seconds": time.perf_counter()-start})
        for trial in range(trials):
            if reset:
                reset()
            begin = time.perf_counter()
            release = begin + len(audio) / 16000
            next_at = begin + .4
            sent = 0
            events = []
            while next_at < release:
                time.sleep(max(0, next_at-time.perf_counter()))
                dispatch = time.perf_counter()
                if dispatch >= release:
                    break
                available = min(len(audio), int((dispatch-begin)*16000))
                value = infer(audio[:available], language, False)
                received = time.perf_counter()
                events.append({"dispatch_ms": (dispatch-begin)*1000,
                    "received_ms": (received-begin)*1000, "available_samples": available,
                    **value})
                if value.get("first_word_elapsed_ms") is not None:
                    events[-1]["first_word_received_ms"] = (dispatch-begin)*1000 + value["first_word_elapsed_ms"]
                sent = available
                # Coalesce a slow inference rather than queue stale prefixes.
                next_at = max(next_at+1, received)
            time.sleep(max(0, release-time.perf_counter()))
            final_dispatch = time.perf_counter()
            value = infer(audio, language, True)
            if finish:
                value = finish(language)
            end = time.perf_counter()
            events.append({"dispatch_ms": (final_dispatch-begin)*1000,
                "received_ms": (end-begin)*1000, "available_samples": len(audio),
                "final": True, **value})
            if value.get("first_word_elapsed_ms") is not None:
                events[-1]["first_word_received_ms"] = (final_dispatch-begin)*1000 + value["first_word_elapsed_ms"]
            nonempty = [e for e in events if words(e.get("text", ""))]
            committed = [e for e in events if words(e.get("committed", ""))]
            gold_first = words(reference)[0]
            correct = [e for e in nonempty if words(e["text"])[0] == gold_first]
            final_first = words(value["text"])
            consistent = [e for e in nonempty if final_first and words(e["text"])[0] == final_first[0]]
            rows.append({"language": language, "trial": trial,
                "audio_seconds": len(audio)/16000,
                "first_text_ms": nonempty[0].get("first_word_received_ms", nonempty[0]["received_ms"]) if nonempty else None,
                "first_text": nonempty[0].get("text") if nonempty else "",
                "first_correct_reference_word_ms": correct[0].get("first_word_received_ms", correct[0]["received_ms"]) if correct else None,
                "first_final_consistent_word_ms": consistent[0].get("first_word_received_ms", consistent[0]["received_ms"]) if consistent else None,
                "first_committed_ms": committed[0]["received_ms"] if committed else None,
                "release_to_final_ms": (end-release)*1000,
                "release_to_final_dispatch_ms": (final_dispatch-release)*1000,
                "text": value["text"], **error_rate(reference, value["text"]), "events": events})
            print(f"LIVE {language}/{trial} first={rows[-1]['first_text_ms']} final={rows[-1]['release_to_final_ms']:.1f}ms", flush=True)
    return {"schema": "asr-paced-runtime.v1", "trials": rows, "fixtures": fixtures,
        "warmups": warmups, "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "policy": "0.4s first prefix, then 1s; monotonic audio availability; serialized/coalesced; full-prefix final",
        "scope": "Paced fixture runtime delivery; no physical mic/UI/cleanup/insertion or duplex acceptance"}


def rpc_driver(child, destination, languages=("en", "fr")):
    pending = bytearray()
    diagnostics = []
    requests = []
    native_stderr = bytearray()
    stderr_open = child.stderr is not None
    def response():
        nonlocal stderr_open
        deadline = time.monotonic() + 120
        while True:
            while b"\n" not in pending:
                if shutil.disk_usage(ROOT).free < 512*1024**2:
                    raise RuntimeError("ASR RPC stopped below 512MiB disk headroom")
                if time.monotonic() >= deadline:
                    raise TimeoutError("ASR RPC response deadline exceeded")
                streams = [child.stdout] + ([child.stderr] if stderr_open else [])
                readable = select.select(streams, [], [], 1)[0]
                if child.stderr in readable:
                    chunk = os.read(child.stderr.fileno(), 65536)
                    if not chunk:
                        stderr_open = False
                    native_stderr.extend(chunk)
                    del native_stderr[:-65536]
                if child.stdout not in readable:
                    continue
                chunk = os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("ASR RPC worker exited before reply")
                pending.extend(chunk)
                if len(pending) > 4*1024**2:
                    raise RuntimeError("ASR RPC reply exceeded bounded buffer")
            line, _, tail = pending.partition(b"\n")
            pending[:] = tail
            if line.startswith(b"ASR_RPC "):
                value = json.loads(line[8:])
                if "error" in value:
                    raise RuntimeError(value["error"])
                return value
            diagnostics.append(line[:2048].decode(errors="replace"))
            del diagnostics[:-20]
    try:
        ready = response()
    except BaseException as error:
        Path(str(destination)+".diagnostic.json").write_text(json.dumps({"error":str(error),
            "runtime_ready":None,"requests":requests,"runtime_stdout_diagnostics":diagnostics,
            "native_stderr_tail":native_stderr.decode(errors="replace")},indent=2)+"\n")
        raise
    def infer(audio, language, final):
        path = ROOT / f"Tests/Fixtures/meetings/{language}-dialogue.wav"
        request = {"language":language,"samples":len(audio),"sent_at":time.monotonic()}
        requests.append(request)
        child.stdin.write((json.dumps({"path": str(path), "samples": len(audio)})+"\n").encode())
        child.stdin.flush()
        value = response()
        request.update(received_at=time.monotonic(), text=value.get("text"),
            native_peak_rss_bytes=value.get("native_peak_rss_bytes"))
        return value
    try:
        result = measure(infer, languages)
    except BaseException as error:
        Path(str(destination)+".diagnostic.json").write_text(json.dumps({"error":str(error),
            "runtime_ready":ready,"requests":requests,"runtime_stdout_diagnostics":diagnostics,
            "native_stderr_tail":native_stderr.decode(errors="replace")},indent=2)+"\n")
        raise
    result["driver_peak_rss_bytes"] = result.pop("peak_rss_bytes")
    result["peak_rss_bytes"] = max([ready.get("native_peak_rss_bytes", 0),
        *[e.get("native_peak_rss_bytes", 0) for row in result["trials"] for e in row["events"]]])
    result["child_memory"] = "native getrusage lifetime peak RSS; not Mach physical footprint"
    result["runtime_ready"] = ready
    result["runtime_stdout_diagnostics"] = diagnostics
    result["native_stderr_tail"] = native_stderr.decode(errors="replace")
    Path(destination).write_text(json.dumps(result, ensure_ascii=False, indent=2)+"\n")
    child.stdin.close()
    child.stdin = None


def whistle_worker(native, destination):
    import ctypes
    process = native.needle_stream_transcribe_process
    process.argtypes = [ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.c_char_p,
        ctypes.c_char_p, ctypes.c_void_p, ctypes.c_int]
    process.restype = ctypes.c_int
    stop = native.needle_stream_transcribe_stop
    stop.argtypes = [ctypes.c_void_p, ctypes.c_int]
    stop.restype = ctypes.c_int
    sent = 0
    committed = []
    def reset():
        nonlocal sent, committed
        sent, committed = 0, []
    def call(fn, *args):
        out = ctypes.create_string_buffer(256*1024)
        if fn(*args, out, len(out)) < 0:
            raise RuntimeError(native.needle_last_error())
        return json.loads(out.value)
    def infer(audio, language, final):
        nonlocal sent
        chunk = audio[sent:]
        pcm = (ctypes.c_float*len(chunk))(*chunk)
        value = call(process, pcm, len(chunk), language.encode(), None)
        sent = len(audio)
        if value.get("text"):
            committed.append(value["text"])
        stable = " ".join(committed)
        return {"text": (stable+" "+value.get("pending", "")).strip(),
            "committed": stable, "native": value}
    def finish(language):
        value = call(stop)
        if value.get("text"):
            committed.append(value["text"])
        return {"text": " ".join(committed), "committed": " ".join(committed), "native": value}
    report = measure(infer, reset=reset, finish=finish)
    # Match vendor's clip length separately; internal TTFT is not live text.
    import ctypes as ct
    from asr_benchmark import read_pcm
    audit = []
    for language in ("en", "fr"):
        pcm = read_pcm(ROOT/f"Tests/Fixtures/meetings/{language}-dialogue.wav")
        for trial in range(3):
            began = time.perf_counter()
            value = call(native.needle_transcribe, pcm, 160000, language.encode(), None, 1)
            audit.append({"language": language, "trial": trial, "audio_seconds": 10,
                "wall_ms": (time.perf_counter()-began)*1000, "result": value})
    report["ten_second_audit"] = audit
    Path(destination).write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")


def qwen_worker(model, folder):
    import mlx.core as mx
    import numpy as np
    def infer(audio, language, final):
        began = time.perf_counter()
        generator = model.generate(np.asarray(audio, dtype=np.float32), stream=True,
            language="English" if language == "en" else "French", max_tokens=256, verbose=False)
        text = ""
        first_word = None
        for result in generator:
            text += result.text
            # Wait for a word boundary rather than crediting a partial token.
            import re
            if first_word is None and re.search(r"[^\W_]+[\s.,!?;:]", text):
                first_word = (time.perf_counter()-began)*1000
        mx.synchronize()
        if first_word is None and words(text):
            first_word = (time.perf_counter()-began)*1000
        return {"text": text, "first_word_elapsed_ms": first_word}
    result = measure(infer)
    result["mlx_peak_memory_bytes"] = mx.get_peak_memory()
    (Path(folder)/"result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2)+"\n")
