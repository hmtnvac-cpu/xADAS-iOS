#!/usr/bin/env python3
import pathlib
import sys

from onnxruntime.quantization import QuantType, quantize_dynamic


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: quantize-ufldv2-model.py INPUT.onnx OUTPUT.onnx")

    source = pathlib.Path(sys.argv[1])
    output = pathlib.Path(sys.argv[2])
    output.parent.mkdir(parents=True, exist_ok=True)
    quantize_dynamic(
        str(source),
        str(output),
        weight_type=QuantType.QUInt8,
        per_channel=True,
        reduce_range=False,
        extra_options={"ActivationSymmetric": False, "WeightSymmetric": False},
    )
    print(f"Created {output} ({output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
