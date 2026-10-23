#!/usr/bin/env python3
"""One-thread diagnostic differential against the pinned upstream v3.2 graph.
This is an independent export check, not a product ONNX/Python dependency.
The graph and generated fixtures must already exist in the owned fixture root.
"""
import argparse
import array
import hashlib
import json
import os
import sys
import wave
from pathlib import Path

for key in ('OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
    os.environ[key] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
os.environ['USE_TORCH'] = '0'
os.environ['USE_TF'] = '0'
os.environ['USE_FLAX'] = '0'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    assert (root / '.nextnotes-turn-fixture').is_file()
    import numpy as np
    import onnxruntime as ort
    from transformers import WhisperFeatureExtractor
    model = root / 'reference-v3.2.onnx'
    options = ort.SessionOptions()
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.inter_op_num_threads = 1
    options.intra_op_num_threads = 1
    session = ort.InferenceSession(str(model), sess_options=options, providers=['CPUExecutionProvider'])
    extractor = WhisperFeatureExtractor(chunk_length=8)
    rows = []
    for fixture in json.loads((root / 'fixtures.json').read_text())['fixtures']:
        path = root / fixture['wav']
        assert hashlib.sha256(path.read_bytes()).hexdigest() == fixture['audioSHA256']
        with wave.open(str(path)) as reader:
            assert (reader.getnchannels(), reader.getframerate(), reader.getsampwidth()) == (1, 16000, 2)
            audio = np.frombuffer(reader.readframes(reader.getnframes()), dtype='<i2').astype(np.float32) / 32768
        points = [('internal-pause', start + min(300, end - start - 10))
                  for start, end in fixture['protectedIntervalsMS']]
        points += [('completed-turn', fixture['speechEndMS'] + 300)]
        for kind, at_ms in points:
            tail = audio[:int(at_ms * 16)][-128000:]
            padded = np.pad(tail, (128000 - len(tail), 0))
            inputs = extractor(padded, sampling_rate=16000, return_tensors='np', padding='max_length',
                               max_length=128000, truncation=True, do_normalize=True)
            features = inputs.input_features.astype(np.float32)
            probability = float(session.run(None, {'input_features': features})[0][0].item())
            rows.append(dict(case=fixture['id'], boundary=kind, probability=probability,
                             semantic_correct=probability >= 0.5 if kind == 'completed-turn' else probability < 0.5,
                             audio_sha256=fixture['audioSHA256']))
    result = dict(schema='nextnotes.turn-export-differential.v1', rows=rows,
                  onnx_sha256=hashlib.sha256(model.read_bytes()).hexdigest(),
                  providers=session.get_providers(), onnxruntime=ort.__version__,
                  scope='Diagnostic same PCM and upstream normalization/Whisper features, one CPU thread; not application latency or product dependency.')
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    for row in rows:
        print(row['case'], row['boundary'], row['probability'], row['semantic_correct'])


if __name__ == '__main__':
    main()
