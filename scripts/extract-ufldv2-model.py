#!/usr/bin/env python3
import pathlib
import shutil
import sys
import tarfile
import urllib.request

ARCHIVE_URL = (
    "https://s3.ap-northeast-2.wasabisys.com/pinto-model-zoo/"
    "324_Ultra-Fast-Lane-Detection-v2/resources.tar.gz"
)
MEMBER_NAME = "ufldv2_tusimple_res18_320x800.onnx"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: extract-ufldv2-model.py OUTPUT.onnx")

    output = pathlib.Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".download")

    request = urllib.request.Request(ARCHIVE_URL, headers={"User-Agent": "xADAS-build"})
    with urllib.request.urlopen(request, timeout=90) as response:
        with tarfile.open(fileobj=response, mode="r|gz") as archive:
            for member in archive:
                if member.name != MEMBER_NAME:
                    continue
                source = archive.extractfile(member)
                if source is None:
                    raise RuntimeError("UFLD V2 model member has no data")
                with temporary.open("wb") as destination:
                    shutil.copyfileobj(source, destination)
                temporary.replace(output)
                print(f"Extracted {output} ({output.stat().st_size} bytes)")
                return

    raise RuntimeError(f"{MEMBER_NAME} was not found in the model archive")


if __name__ == "__main__":
    main()
