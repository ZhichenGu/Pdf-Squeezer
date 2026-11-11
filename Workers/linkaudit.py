"""Inspect explicit PDF link annotations without opening their targets."""
import json
from urllib.parse import urljoin,urlsplit
from pypdf import PdfReader
from pypdf.generic import IndirectObject,DictionaryObject,ArrayObject,NullObject

def inventory(reader):
    pages={p.indirect_reference.idnum:i+1 for i,p in enumerate(reader.pages)}
    named=reader.named_destinations
    base=str(reader.root_object.get("/URI",{}).get_object().get("/Base","")) if "/URI" in reader.root_object else ""
    records=[]
    def signature(value,seen=frozenset()):
        if isinstance(value,IndirectObject):
            ident=(value.idnum,value.generation)
            if ident in seen: return "cycle"
            obj=value.get_object()
            if isinstance(obj,DictionaryObject) and obj.get("/Type")=="/Page":
                return ["page",pages.get(value.idnum)]
            return signature(obj,seen|{ident})
        if isinstance(value,DictionaryObject):
            return {str(k):signature(v,seen) for k,v in value.items() if k!="/P"}
        if isinstance(value,ArrayObject): return [signature(v,seen) for v in value]
        if isinstance(value,bytes): return value.hex()
        return str(value) if value is not None else None
    for index,page in enumerate(reader.pages,1):
        for ref in page.get("/Annots",[]).get_object() if "/Annots" in page else []:
            link=ref.get_object()
            if not isinstance(link,dict) or link.get("/Subtype")!="/Link": continue
            a=link.get("/A")
            a=a.get_object() if a else {}
            kind=str(a.get("/S","/GoTo")).lstrip("/")
            value=link.get("/Dest",a.get("/D"))
            uri=""
            if kind=="GoTo":
                resolved=value.get_object() if hasattr(value,"get_object") else value
                if not isinstance(resolved,list):
                    dest=named.get(str(resolved))
                    resolved=dest.dest_array if dest else []
                p=resolved[0] if resolved else None
                n=pages.get(p.idnum) if isinstance(p,IndirectObject) else None
                label=f"跳至第 {n} 页" if n else "内部跳页"
                status="目标页有效" if n else "找不到目标页"
                problem=n is None
            elif kind=="URI":
                uri=urljoin(base,str(a.get("/URI","")).strip())
                label=uri or "空网址"
                try:
                    u=urlsplit(uri)
                    web=u.scheme.lower() in ("https","http")
                    valid=bool(u.hostname if web else u.scheme and u.path) and not any(c.isspace() for c in uri)
                    _=u.port
                except ValueError: valid=False;web=False
                status=("待联网检测" if web else "需用关联应用打开") if valid else "地址格式无效"
                problem=not valid
            else:
                label={"GoToR":"外部文件跳转","Launch":"打开外部文件","Named":"阅读器导航"}.get(kind,kind)
                status="需在阅读器中验证"
                problem=False
            records.append(dict(page=index,kind=kind,label=label,url=uri,status=status,problem=problem,
              signature=[signature(link.get("/Rect")),signature(a),signature(value),label]))
    return records

if __name__=="__main__":
    import sys
    print(json.dumps(inventory(PdfReader(sys.argv[1])),ensure_ascii=False))
