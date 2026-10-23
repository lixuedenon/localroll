# scripts/models/export_clip.py
#
# Makes the picture-search model files LocalRoll downloads (from this repo's
# "deps" release): OpenCLIP ViT-B/32 + XLM-RoBERTa (LAION-5B, MIT licence),
# as two ONNX models (picture, text), 8-bit, plus the text tokenizer's
# vocabulary and sample tokenizations (to check the app's own tokenizer).
# Run by .github/workflows/models.yml.
import hashlib
import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort
import open_clip
import torch
from onnxruntime.quantization import QuantType, quantize_dynamic
from transformers import AutoTokenizer

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)
NAME, PRETRAINED = "xlm-roberta-base-ViT-B-32", "laion5b_s13b_b90k"
CTX = 77

model, _, preprocess = open_clip.create_model_and_transforms(NAME, pretrained=PRETRAINED)
model.eval()
# The fast attention path has no ONNX form: the plain one exports.
torch.backends.mha.set_fastpath_enabled(False)
print("preprocess:", preprocess)


class Picture(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, pixels):
        e = self.m.encode_image(pixels)
        return e / e.norm(dim=-1, keepdim=True)


class Text(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, ids):
        e = self.m.encode_text(ids)
        return e / e.norm(dim=-1, keepdim=True)


tok = AutoTokenizer.from_pretrained("xlm-roberta-base")
pix = torch.randn(1, 3, 224, 224)
ids = torch.tensor(tok(["a dog on the beach"], max_length=CTX, padding="max_length", truncation=True)["input_ids"])

with torch.no_grad():
    torch.onnx.export(Picture(model), pix, f"{OUT}/picture_fp32.onnx", input_names=["pixels"], output_names=["embedding"],
                      dynamic_axes={"pixels": {0: "n"}, "embedding": {0: "n"}}, opset_version=17)
    torch.onnx.export(Text(model), ids, f"{OUT}/text_fp32.onnx", input_names=["ids"], output_names=["embedding"],
                      dynamic_axes={"ids": {0: "n"}, "embedding": {0: "n"}}, opset_version=17)

for n in ["picture", "text"]:
    # Matrix products and the word table (nearly all the weights); 8-bit convolutions
    # have no CPU implementation in ONNX Runtime 1.15.
    quantize_dynamic(f"{OUT}/{n}_fp32.onnx", f"{OUT}/clip-{n}.onnx", weight_type=QuantType.QInt8,
                     op_types_to_quantize=["MatMul", "Gemm", "Gather"])

# How close 8-bit is to the original, and how fast (this runner's CPU).
report = {}
opts = ort.SessionOptions()
opts.intra_op_num_threads = 2
for n, x in [("picture", pix.numpy()), ("text", ids.numpy())]:
    a = ort.InferenceSession(f"{OUT}/{n}_fp32.onnx", opts, providers=["CPUExecutionProvider"])
    b = ort.InferenceSession(f"{OUT}/clip-{n}.onnx", opts, providers=["CPUExecutionProvider"])
    inp = a.get_inputs()[0].name
    ea, eb = a.run(None, {inp: x})[0][0], b.run(None, {inp: x})[0][0]
    t = time.time()
    for _ in range(20):
        b.run(None, {inp: x})
    report[n] = {"cosine_fp32_vs_int8": float(np.dot(ea, eb)), "ms_per_item_2_threads": (time.time() - t) / 20 * 1000,
                 "mb": os.path.getsize(f"{OUT}/clip-{n}.onnx") / 1e6, "dim": int(eb.shape[0])}

# Zero-shot sanity check on a made-up picture is meaningless; instead check
# that related texts are closer than unrelated ones, in several languages.
b = ort.InferenceSession(f"{OUT}/clip-text.onnx", opts, providers=["CPUExecutionProvider"])


def emb(s):
    i = tok([s], max_length=CTX, padding="max_length", truncation=True)["input_ids"]
    return b.run(None, {"ids": np.array(i, dtype=np.int64)})[0][0]


pairs = [("a dog", "一只狗", "a mountain covered in snow"), ("birthday cake", "生日蛋糕", "a car on a highway"),
         ("beach", "海边", "an office desk"), ("beach", "ビーチ", "a bowl of rice")]
report["text_checks"] = [{"pair": [p, q], "related": float(np.dot(emb(p), emb(q))), "unrelated": float(np.dot(emb(p), emb(r)))}
                         for p, q, r in pairs]

# Tokenizer: the vocabulary (SentencePiece unigram) and samples.
tj = json.loads(tok.backend_tokenizer.to_str())
vocab = tj["model"]["vocab"]  # [[piece, score], ...] in id order
with open(f"{OUT}/clip-vocab.json", "w", encoding="utf-8") as f:
    json.dump({"vocab": vocab, "unk": tj["model"].get("unk_id", 3), "bos": tok.bos_token_id, "eos": tok.eos_token_id,
               "pad": tok.pad_token_id, "ctx": CTX}, f, ensure_ascii=False)
samples = ["a dog on the beach", "海边的日落", "生日蛋糕", "WiFi 密码", "Schnee in den Bergen", "東京タワー", "고양이",
           "ＡＢＣ　全角", "e-mail 2026-10-22", "  spaces  ", "Ünïcödé café"]
with open(f"{OUT}/clip-token-samples.json", "w", encoding="utf-8") as f:
    json.dump([{"text": s, "ids": tok([s], max_length=CTX, truncation=True)["input_ids"][0]} for s in samples], f, ensure_ascii=False)

files = {}
for n in ["clip-picture.onnx", "clip-text.onnx", "clip-vocab.json"]:
    with open(f"{OUT}/{n}", "rb") as f:
        data = f.read()
    files[n] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
report["files"] = files
report["model"] = f"{NAME} / {PRETRAINED}"
report["preprocess"] = str(preprocess)
print(json.dumps(report, indent=2, ensure_ascii=False))
with open(f"{OUT}/report.json", "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, ensure_ascii=False)
