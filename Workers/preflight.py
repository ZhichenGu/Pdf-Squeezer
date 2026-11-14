"""Inspect stream storage and prune XObjects absent from their content streams."""
import json
import sys
from collections import Counter
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ContentStream, DictionaryObject, NameObject as N
from linkaudit import inventory


def analyze(reader):
    totals = Counter()
    seen = set()
    def walk(value, category="其他"):
        if hasattr(value, "idnum"):
            key = (value.idnum, value.generation)
            if key in seen:
                return
            seen.add(key)
        obj = value.get_object() if hasattr(value, "get_object") else value
        if hasattr(obj, "_data"):
            kind = "图片" if obj.get("/Subtype") == "/Image" else category
            totals[kind] += len(obj._data)
        if isinstance(obj, dict):
            for key, child in obj.items():
                group = "字体" if key in ("/FontFile", "/FontFile2", "/FontFile3") else category
                if key == "/Contents" or obj.get("/Subtype") == "/Form":
                    group = "文字与矢量"
                walk(child, group)
        elif isinstance(obj, list):
            for child in obj:
                walk(child, category)
    walk(reader.trailer["/Root"])
    total = sum(totals.values()) or 1
    return " · ".join(f"{key} {round(size / total * 100)}%" for key, size in totals.most_common())


def clean(reader, destination):
    writer = PdfWriter(clone_from=reader)
    visited = set()
    removed = 0
    def prune(owner, stream, resources):
        nonlocal removed
        if stream is None or resources is None:
            return
        # A copied resource dictionary avoids changing a shared page resource.
        try:
            used = {args[0] for args, op in ContentStream(stream, writer).operations
                    if op == b"Do" and args}
        except Exception:
            return
        resources = resources.get_object()
        objects = resources.get("/XObject")
        if objects is None:
            return
        kept = DictionaryObject()
        for name, ref in objects.get_object().items():
            if name not in used:
                removed += 1
                continue
            kept[name] = ref
            obj = ref.get_object()
            identity = id(obj)
            if obj.get("/Subtype") == "/Form" and identity not in visited:
                visited.add(identity)
                prune(obj, obj, obj.get("/Resources", resources))
        updated = DictionaryObject(resources)
        updated[N("/XObject")] = kept
        owner[N("/Resources")] = updated
    for page in writer.pages:
        prune(page, page.get_contents(), page.get("/Resources"))
    writer.pdf_header = max("%PDF-1.7", reader.pdf_header)
    writer.compress_identical_objects()
    writer.write(destination)
    verified = PdfReader(destination)
    if len(verified.pages) != len(reader.pages) or inventory(reader) != inventory(verified):
        raise ValueError("资源清理后的页数或链接校验失败")
    return removed


if __name__ == "__main__":
    print(json.dumps({"summary": analyze(PdfReader(sys.argv[1]))}, ensure_ascii=False))
