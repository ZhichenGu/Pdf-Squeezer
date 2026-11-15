"""Regression checks for size search, resource cleanup and PDF preservation."""
import io
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/"Workers"))
from PIL import Image
from pypdf import PdfReader,PdfWriter
from pypdf.generic import (ArrayObject,DictionaryObject,DecodedStreamObject,
    EncodedStreamObject,NameObject as N,NumberObject,FloatObject,TextStringObject)
from linkaudit import inventory
from preflight import clean

with open(ROOT/"Resources/Info.plist", "rb") as file:
    app_name=plistlib.load(file)["CFBundleName"]
APP=ROOT/"dist"/(app_name+".app")/"Contents/Resources"


def fixture(path):
    writer=PdfWriter()
    page=writer.add_blank_page(600,400)
    img=Image.effect_noise((1800,1200),60).convert("RGB")
    data=io.BytesIO();img.save(data,"JPEG",quality=96)
    image=EncodedStreamObject()
    image.update({N("/Type"):N("/XObject"),N("/Subtype"):N("/Image"),
        N("/Width"):NumberObject(1800),N("/Height"):NumberObject(1200),
        N("/ColorSpace"):N("/DeviceRGB"),N("/BitsPerComponent"):NumberObject(8),
        N("/Filter"):N("/DCTDecode")})
    image._data=data.getvalue()
    font=DictionaryObject({N("/Type"):N("/Font"),N("/Subtype"):N("/Type1"),N("/BaseFont"):N("/Helvetica")})
    resources=DictionaryObject({N("/XObject"):DictionaryObject({N("/Photo"):writer._add_object(image),N("/Unused"):writer._add_object(DecodedStreamObject())}),
        N("/Font"):DictionaryObject({N("/F1"):writer._add_object(font)})})
    page[N("/Resources")]=resources
    stream=DecodedStreamObject()
    stream.set_data(b"q 600 0 0 400 0 0 cm /Photo Do Q\nBT /F1 18 Tf 20 370 Td (Quality and links 123) Tj ET")
    page[N("/Contents")]=writer._add_object(stream)
    annotation=DictionaryObject({N("/Type"):N("/Annot"),N("/Subtype"):N("/Link"),
        N("/Rect"):ArrayObject([NumberObject(n) for n in (20,360,230,390)]),
        N("/A"):DictionaryObject({N("/S"):N("/URI"),N("/URI"):TextStringObject("https://example.com/test")})})
    page[N("/Annots")]=ArrayObject([writer._add_object(annotation)])
    writer.add_blank_page(400,300)
    writer.add_outline_item("Second page",1)
    writer.add_named_destination("second",1)
    writer.write(path)


class CompressionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.folder=Path(self.temp.name)
        self.source=self.folder/"source.pdf"
        fixture(self.source)
    def tearDown(self):
        self.temp.cleanup()
    def worker(self,output,cap,dpi,quality,adaptive):
        process=subprocess.run([sys.executable,"-B",APP/"engine.py",self.source,output,str(cap),str(dpi),str(quality),str(int(adaptive))],capture_output=True,text=True,check=True)
        return process.stdout
    def preserved(self,result):
        a,b=PdfReader(self.source),PdfReader(result)
        self.assertEqual(len(a.pages),len(b.pages))
        self.assertEqual(inventory(a),inventory(b))
        self.assertEqual(a.pages[0].extract_text(),b.pages[0].extract_text())
        self.assertEqual(set(a.named_destinations),set(b.named_destinations))
        self.assertEqual(len(a.outline),len(b.outline))
    def test_already_below_target_still_applies_settings(self):
        high,low=self.folder/"high.pdf",self.folder/"low.pdf"
        self.worker(high,50_000_000,180,90,False)
        self.worker(low,50_000_000,96,45,False)
        self.assertLess(low.stat().st_size,high.stat().st_size*.8)
        self.preserved(low)
    def test_adaptive_refines_between_pass_and_fail(self):
        output=self.folder/"adaptive.pdf"
        log=self.worker(output,200000,300,96,True)
        self.assertLessEqual(output.stat().st_size,200000)
        self.assertIn("轮",log)
        # Ensure refinement increased the selected feasible scale after first success.
        self.assertGreater(output.stat().st_size,170000)
        self.preserved(output)
    def test_cleanup_preserves_resources_and_navigation(self):
        out=self.folder/"clean.pdf"
        removed=clean(PdfReader(self.source),out)
        self.assertEqual(removed,1)
        self.assertIn("/Photo",PdfReader(out).pages[0]["/Resources"]["/XObject"])
        self.assertNotIn("/Unused",PdfReader(out).pages[0]["/Resources"]["/XObject"])
        self.preserved(out)
    def test_strong_preserves_search_links_and_blank_page(self):
        out=self.folder/"strong.pdf"
        subprocess.run([sys.executable,"-B",APP/"strong.py",self.source,out,"45000"],check=True,stdout=subprocess.DEVNULL)
        self.assertLessEqual(out.stat().st_size,45000)
        self.preserved(out)
    def test_invalid_pdf_fails(self):
        self.source.write_bytes(b"broken")
        with self.assertRaises(subprocess.CalledProcessError):
            self.worker(self.folder/"invalid.pdf",100000,180,85,True)


if __name__=="__main__":
    if "--fixture" in sys.argv:
        fixture(Path(sys.argv[-1]))
    else:
        unittest.main()
