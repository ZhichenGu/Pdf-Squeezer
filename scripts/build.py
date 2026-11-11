#!/usr/bin/env python3
"""Build and verify the standalone Apple Silicon application and its release ZIP."""
import hashlib
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
DIST = ROOT / "dist"

def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)

def dependency(item):
    cache = BUILD / "downloads" / item["name"]
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.exists():
        with urllib.request.urlopen(item["url"], timeout=120) as response, tempfile.NamedTemporaryFile(dir=cache.parent) as tmp:
            shutil.copyfileobj(response, tmp)
            tmp.flush()
            shutil.copyfile(tmp.name, cache)
    if hashlib.sha256(cache.read_bytes()).hexdigest() != item["sha256"]:
        cache.unlink()
        raise ValueError("依赖校验失败，请重试："+item["name"])
    return cache

def build():
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("请在 Apple Silicon Mac 上构建。")
    DIST.mkdir(exist_ok=True)
    archive, *wheels = map(dependency, json.loads((ROOT/"scripts/dependencies.json").read_text()))
    with tempfile.TemporaryDirectory(dir=BUILD) as temp:
        stage=Path(temp)
        run("tar","-xzf",archive,"-C",stage)
        python=stage/"python"
        app=stage/"PDF压缩.app"
        contents=app/"Contents"
        bin_dir=contents/"MacOS"
        res=contents/"Resources"
        bin_dir.mkdir(parents=True)
        res.mkdir()
        shutil.copy2(ROOT/"Resources/Info.plist",contents)
        shutil.copy2(ROOT/"Resources/PaperPress.icns",res)
        for worker in (ROOT/"Workers").glob("*.py"):
            shutil.copy2(worker,res)
        runtime=res/"runtime"
        (runtime/"bin").mkdir(parents=True)
        shutil.copy2(python/"bin/python3.12",runtime/"bin")
        lib=Path("lib/python3.12")
        ignore=shutil.ignore_patterns("__pycache__","*.pyc","site-packages","test","tests","idlelib","tkinter","turtledemo","ensurepip","config-*")
        shutil.copytree(python/lib,runtime/lib,ignore=ignore)
        for dylib in (python/"lib").glob("libpython*.dylib"):
            shutil.copy2(dylib,runtime/"lib")
        if (python/"licenses").is_dir():
            shutil.copytree(python/"licenses",runtime/"licenses")
        for wheel in wheels:
            with zipfile.ZipFile(wheel) as file:
                file.extractall(runtime/lib/"site-packages")
        swift=["xcrun","swiftc","-swift-version","5","-O","-target","arm64-apple-macos14.0","-module-cache-path",BUILD/"swift-cache"]
        source=ROOT/"Sources"
        run(*swift,source/"Raster.swift","-o",res/"PageRender")
        run(*swift,*[source/n for n in ("App.swift","Model.swift","Preview.swift","SizeWarning.swift")],"-o",bin_dir/"PaperPress")
        run(runtime/"bin/python3.12","-B","-c","from PIL import Image; from pypdf import PdfReader; Image.new('RGB',(2,2)).tobytes()")
        run("codesign","--force","--deep","--sign","-",app)
        run("codesign","--verify","--strict","--deep",app)
        version=plistlib.loads((contents/"Info.plist").read_bytes())["CFBundleShortVersionString"]
        name=f"PDF-Squeezer-v{version}-macOS-arm64.zip"
        run("ditto","-c","-k","--norsrc","--keepParent",app,stage/name)
        final=DIST/app.name
        if final.exists():
            shutil.rmtree(final)
        shutil.move(str(app),final)
        os.replace(stage/name,DIST/name)
        digest=hashlib.sha256((DIST/name).read_bytes()).hexdigest()
        (DIST/(name+".sha256")).write_text(f"{digest}  {name}\n")
        print(DIST/name)

if __name__ == "__main__":
    build()
