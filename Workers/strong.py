"""Size-first output: a rendered page plus its original searchable text and links."""
import io
import logging
from pathlib import Path
import subprocess
import sys
import tempfile
from PIL import Image
from pypdf import PdfReader, PdfWriter
from pypdf.generic import (ContentStream, DecodedStreamObject, DictionaryObject,
                           NameObject as N, NumberObject)
from linkaudit import inventory

TEXT_OPS = set(b"q Q cm BT ET Tf Tc Tw Tz TL Ts Td TD Tm T* Tj TJ ' \" BMC BDC EMC MP DP".split())


def text_layer(stream, resources, reader, parents=()):
    content = ContentStream(stream, reader)
    kept = []
    used = DictionaryObject()
    forms = DictionaryObject()
    for args, op in content.operations:
        if op in TEXT_OPS:
            kept.append((args, op))
        elif op == b"Do":
            source = resources.get("/XObject")
            if source is None: continue
            obj = source.get_object().get(args[0])
            if obj is None or obj in parents: continue
            form = obj.get_object()
            if form.get("/Subtype") != "/Form": continue
            if args[0] not in forms:
                nested, refs = text_layer(form, form.get("/Resources",resources).get_object(),
                                          reader,parents+(obj,))
                layer=DecodedStreamObject()
                layer.set_data(nested)
                for key in ("/Type","/Subtype","/BBox","/Matrix","/StructParents"):
                    if key in form: layer[N(key)] = form.raw_get(key)
                layer[N("/Resources")]=refs
                forms[args[0]]=layer.flate_encode()
            kept.append((args,op))
        elif op == b"gs":
            # An extended graphics state can supply a text font.
            states=resources.get("/ExtGState")
            if states:
                gs=states.get_object().get(args[0])
                if gs and "/Font" in gs.get_object():
                    used.setdefault(N("/ExtGState"),DictionaryObject())[args[0]]=DictionaryObject(
                        {N("/Font"):gs.get_object().raw_get("/Font")})
                    kept.append((args,op))
    for key in ("/Font","/Properties"):
        if key in resources: used[N(key)] = resources.raw_get(key)
    if forms: used[N("/XObject")] = forms
    content.operations = kept
    return content.get_data(),used


def run(src, out, cap):
    reader=PdfReader(src)
    original_links=inventory(reader)
    with tempfile.TemporaryDirectory(dir=out.parent) as temp:
        tmp=Path(temp)
        subprocess.run([Path(__file__).with_name("PageRender"),src,tmp],check=True)
        images=[]
        for index,page in enumerate(reader.pages,1):
            contents=page.get_contents()
            if contents is None:
                text,resources=b"",DictionaryObject()
            else:
                text,resources=text_layer(contents,page.get("/Resources",DictionaryObject()).get_object(),reader)
            box=page.cropbox
            matrix=" ".join(format(float(v),".9f") for v in [box.width,0,0,box.height,box.left,box.bottom])
            # Render an opaque snapshot first, then invisible text above it.
            # Drop Tr instructions in the text copy so rendering mode remains 3.
            forms=resources.setdefault(N("/XObject"),DictionaryObject())
            name="/PPPage"
            while name in forms: name+="_"
            stream=DecodedStreamObject()
            stream.set_data(f"q {matrix} cm {name} Do Q\nq 3 Tr\n".encode()+text+b"\nQ\n")
            page[N("/Contents")]=stream.flate_encode()
            image=DecodedStreamObject()
            image.update({N("/Type"):N("/XObject"),N("/Subtype"):N("/Image"),
                N("/ColorSpace"):N("/DeviceRGB"),N("/BitsPerComponent"):NumberObject(8),
                N("/Filter"):N("/DCTDecode")})
            forms[N(name)]=image
            page[N("/Resources")]=resources
            page.indirect_reference.get_object().update({N("/Resources"):resources,N("/Contents"):page.raw_get("/Contents")})
            images.append(image)
        for dpi,quality in [(180,86),(155,78),(135,72),(117,65),(111,64),(105,62),(100,60),(85,54),(72,45),(60,38),(48,32),(36,25)]:
            print(f"强力压缩 · {dpi} DPI · 质量 {quality}%",flush=True)
            for index,image in enumerate(images):
                with Image.open(tmp/f"{index+1}.png") as original:
                    im=original.convert("RGB")
                box=reader.pages[index].cropbox
                im.thumbnail((max(1,round(float(box.width)*dpi/72)),max(1,round(float(box.height)*dpi/72))),Image.Resampling.LANCZOS)
                data=io.BytesIO()
                im.save(data,"JPEG",quality=quality,optimize=True)
                image._data=data.getvalue()
                image[N("/Width")]=NumberObject(im.width)
                image[N("/Height")]=NumberObject(im.height)
            w=PdfWriter(clone_from=reader)
            w.pdf_header=max("%PDF-1.7",reader.pdf_header)
            w.compress_identical_objects()
            w.write(out)
            if out.stat().st_size<=cap:
                check=PdfReader(out)
                if len(check.pages)!=len(reader.pages) or inventory(check)!=original_links:
                    raise ValueError("页数或链接校验失败。")
                return
        raise ValueError("已达到强压下限，仍无法满足目标。可调整目标或导出之前的结果。")

if __name__=="__main__":
    logging.getLogger("pypdf").setLevel(logging.ERROR)
    try: run(Path(sys.argv[1]),Path(sys.argv[2]),int(sys.argv[3]))
    except Exception as exc:
        print(str(exc),flush=True)
        sys.exit(1)
