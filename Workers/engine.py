"""Local PDF compression worker. One process owns one document."""
import io
import logging
import math
import os
import re
import shutil
import sys
import tempfile
import zlib
import signal
from pathlib import Path

from linkaudit import inventory
from preflight import clean, analyze
from PIL import Image
from pypdf import PdfReader, PdfWriter, Transformation
from pypdf.generic import ContentStream, DecodedStreamObject, NameObject, NumberObject

logging.getLogger("pypdf").setLevel(logging.ERROR)
N = NameObject
DRAW_LINE = re.compile(rb"(?m)^([-+\d. ]+) (m|l|c|v|y|re)$")
NON_POSITION = re.compile(rb"(?m)^(?:[-\d. ]+ (?:m|l|c|v|y|re|scn|w)|[fhns])\r?$")
DECIMAL = re.compile(rb"-?\d+\.\d+")
IDENTITY = Transformation()
Image.MAX_IMAGE_PIXELS = 100_000_000


def simple_stream(raw):
    # Literal strings and inline image data can contain operator-like lines.
    return b"(" not in raw and re.search(rb"(?:^|\s)BI(?:\s|$)", raw) is None


def placements(reader):
    sizes = {}
    def scan(stream, resources, transform, parents):
        raw = stream.get_data()
        if b"Do" not in raw or len(parents) > 40:
            return
        cleaned = DecodedStreamObject()
        cleaned.set_data(NON_POSITION.sub(b"", raw) if simple_stream(raw) else raw)
        stack = []
        objects = resources.get("/XObject", {})
        objects = objects.get_object() if hasattr(objects, "get_object") else objects
        for args, op in ContentStream(cleaned, reader).operations:
            if op == b"q":
                stack.append(transform)
            elif op == b"Q" and stack:
                transform = stack.pop()
            elif op == b"cm" and len(args) == 6:
                transform = Transformation(tuple(map(float, args))).transform(transform)
            elif op == b"Do" and args and args[0] in objects:
                ref = objects.raw_get(args[0])
                obj = ref.get_object()
                if not hasattr(ref, "idnum"):
                    continue
                if obj.get("/Subtype") == "/Image":
                    a,b,c,d,_,_ = transform.ctm
                    w,h = sizes.get(ref.idnum,(0,0))
                    sizes[ref.idnum] = max(w,math.hypot(a,b)),max(h,math.hypot(c,d))
                elif obj.get("/Subtype") == "/Form" and ref.idnum not in parents:
                    matrix = Transformation(tuple(map(float,obj.get("/Matrix",IDENTITY.ctm))))
                    scan(obj, obj.get("/Resources",resources).get_object(), matrix.transform(transform), parents | {ref.idnum})
    for page in reader.pages:
        if "/Contents" in page and "/Resources" in page:
            scan(page.get_contents(), page["/Resources"], IDENTITY.scale(page.user_unit),set())
    return sizes


def compact_paths(match):
    # Figma exports coordinate lists with six fractional places.
    def compact(number):
        val = (b"%.2f" % float(number[0])).rstrip(b"0").rstrip(b".")
        return b"0" if val == b"-0" else val
    return DECIMAL.sub(compact, match[0])


def compact_figma(raw):
    # Handle PDFs with single-line literal strings; skip multiline variants.
    if re.search(rb"(?:^|\s)BI(?:\s|$)", raw):
        return raw
    lines = raw.splitlines(keepends=True)
    for line in lines:
        if b"(" in line or b")" in line:
            escaped = re.sub(rb"\\.", b"", line)
            if escaped.count(b"(") != escaped.count(b")"):
                return raw
    return DRAW_LINE.sub(compact_paths,raw)


def prepare(reader):
    figma = (reader.metadata and reader.metadata.producer == "Figma")
    if not figma:
        return
    for gen, entries in reader.xref.items():
        if gen != 0:
            continue
        for number in entries:
            if not number: continue
            obj = reader.get_object(number)
            if not hasattr(obj,"_data") or obj.get("/Filter") != "/FlateDecode" or obj.get("/Subtype") not in (None,"/Form"):
                continue
            raw = obj.get_data()
            if raw.startswith((b"q\n",b"/C1 CS\n")):
                obj._data = zlib.compress(compact_figma(raw),9)
                obj.decoded_self = None


def run(src, dest, limit, dpi, quality, adaptive):
    reader = PdfReader(src)
    if reader.is_encrypted:
        raise ValueError("请先解锁并另存这份 PDF。")
    if not len(reader.pages):
        raise ValueError("PDF 中没有页面。")
    original = os.stat(src).st_size
    print("分析 · " + analyze(reader), flush=True)
    with tempfile.TemporaryDirectory(dir=str(Path(dest).parent)) as folder:
        cleaned = Path(folder) / "clean.pdf"
        removed = clean(reader, cleaned)
        if cleaned.stat().st_size < original:
            reader = PdfReader(io.BytesIO(cleaned.read_bytes()))
        print(f"资源清理 · 移除 {removed} 个未使用图片或图形", flush=True)
    sizes = placements(reader)
    prepare(reader)
    sources = []
    for number, (w,h) in sizes.items():
        obj = reader.get_object(number)
        filt = obj.get("/Filter")
        filt = list(filt) if isinstance(filt,list) else [filt]
        colors = obj.get("/ColorSpace")
        colors = colors.get_object() if colors is not None else None
        mode = {"/DeviceRGB":"RGB","/DeviceGray":"L"}.get(str(colors)) if not isinstance(colors,list) else None
        if isinstance(colors,list) and colors[0] == "/ICCBased":
            mode = {1:"L",3:"RGB"}.get(colors[1].get_object().get("/N"))
        if not mode or obj.get("/BitsPerComponent") != 8 or "/Mask" in obj or "/Decode" in obj or obj.get("/ImageMask"):
            continue
        if filt and filt[0] in ("/ASCII85Decode","/ASCIIHexDecode"):
            filt=filt[1:]
        if filt not in (["/DCTDecode"], ["/FlateDecode"], [None]) or len(obj._data)<2048:
            continue
        ow, oh = int(obj["/Width"]),int(obj["/Height"])
        if ow*oh>100_000_000: continue
        sources.append((obj,obj._data,ow,oh,w,h,mode,filt,obj.get("/DecodeParms"),obj.get("/Filter")))
        if "/SMask" in obj:
            mask=obj["/SMask"]
            if mask.get("/BitsPerComponent")==8 and "/Decode" not in mask and "/Matte" not in mask and mask.get_data().strip(b"\xff")==b"":
                del obj["/SMask"]
    best = original
    shutil.copyfile(src,dest)
    feasible = None
    selected = (dpi, quality)
    failed_scale = 1.0
    passed_scale = None
    scale = 1.0
    initial_dpi, initial_quality = dpi, quality
    with tempfile.TemporaryDirectory(dir=str(Path(dest).parent)) as tmp:
        candidate = Path(tmp)/"candidate.pdf"
        # Try user settings first, then use the observed size to tune the next pass.
        for attempt in range(13 if adaptive else 1):
            dpi = max(min(initial_dpi, 72), round(initial_dpi * scale))
            quality = max(min(initial_quality, 45), round(initial_quality * scale))
            print(f"第 {attempt+1} 轮 · {dpi} DPI · 质量 {quality}%",flush=True)
            for obj,data,ow,oh,w,h,mode,filt,params,orig_filter in sources:
                obj._data=data
                obj.decoded_self=None
                for key,value in (("/Width",NumberObject(ow)),("/Height",NumberObject(oh)),("/Filter",orig_filter),("/DecodeParms",params)):
                    if value is not None: obj[N(key)]=value
                    else: obj.pop(key,None)
                try:
                    if filt == ["/DCTDecode"]:
                        im=Image.open(io.BytesIO(obj.get_data()))
                        if im.mode!=mode: continue
                    else:
                        im=Image.frombytes(mode,(ow,oh),obj.get_data())
                    factor=min(1,max(w*dpi/(72*ow),h*dpi/(72*oh)))
                    if factor<=0: continue
                    if factor<0.99:
                        im=im.resize((max(1,round(ow*factor)),max(1,round(oh*factor))),Image.Resampling.LANCZOS)
                    output=io.BytesIO()
                    im.save(output,format="JPEG",optimize=True,quality=quality)
                    if len(output.getvalue()) >= len(data): continue
                    obj._data=output.getvalue()
                    obj[N("/Filter")]=N("/DCTDecode")
                    obj.pop("/DecodeParms",None)
                    obj[N("/Width")],obj[N("/Height")]=map(NumberObject,im.size)
                    obj.decoded_self=None
                except (OSError,ValueError):
                    continue
            writer=PdfWriter(clone_from=reader)
            writer.pdf_header=max("%PDF-1.7",reader.pdf_header)
            writer.compress_identical_objects()
            writer.write(candidate)
            size=candidate.stat().st_size
            if size <= limit:
                # Highest feasible scale wins, even if its bytes exceed a lower-quality pass.
                if passed_scale is None or scale > passed_scale:
                    shutil.copyfile(candidate, dest)
                    feasible = size
                    selected = (dpi, quality)
                    passed_scale = scale
                if scale == 1 or failed_scale - passed_scale < .015:
                    break
                scale = (passed_scale + failed_scale) / 2
            else:
                if feasible is None and size < best:
                    shutil.copyfile(candidate, dest)
                    best = size
                    selected = (dpi, quality)
                failed_scale = scale
                if passed_scale is not None:
                    scale = (passed_scale + failed_scale) / 2
                else:
                    if not sources or (dpi <= 72 and quality <= 45):
                        break
                    scale *= min(.87, max(.55, math.sqrt(limit / size) * .97))
            if not adaptive:
                break
    if os.stat(dest).st_size > original and original <= limit:
        shutil.copyfile(src, dest)
    dpi, quality = selected
    print(f"结果 · {os.stat(dest).st_size} 字节 · {dpi} DPI · 质量 {quality}%", flush=True)
    verified=PdfReader(dest)
    if inventory(reader)!=inventory(verified):
        raise ValueError("链接目标校验失败，请保留原稿。")
    if len(verified.pages)!=len(reader.pages):
        raise ValueError("结果校验失败。")

if __name__=="__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        run(sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4]),int(sys.argv[5]),sys.argv[6]=="1")
    except Exception as exc:
        print("处理失败 · "+str(exc),flush=True)
        sys.exit(1)
