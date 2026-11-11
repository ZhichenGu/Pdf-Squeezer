import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func renderPages(_ file: URL, directory: URL) throws {
    guard let document = CGPDFDocument(file as CFURL) else { throw CocoaError(.fileReadCorruptFile) }
    for index in 1...document.numberOfPages {
        try autoreleasepool {
            guard let page = document.page(at: index) else { throw CocoaError(.fileReadCorruptFile) }
            let box = page.getBoxRect(.cropBox)
            guard box.width > 0 && box.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let scale = min(2.5, 4600 / max(box.width,box.height))
            let w = max(1,Int(ceil(box.width*scale))), h = max(1,Int(ceil(box.height*scale)))
            guard let ctx = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw CocoaError(.fileReadTooLarge) }
            ctx.setFillColor(gray:1,alpha:1)
            ctx.fill(CGRect(x:0,y:0,width:w,height:h))
            ctx.scaleBy(x:CGFloat(w)/box.width,y:CGFloat(h)/box.height)
            ctx.translateBy(x:-box.minX,y:-box.minY)
            ctx.drawPDFPage(page)
            let url=directory.appendingPathComponent("\(index).png")
            guard let image=ctx.makeImage(),let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else{throw CocoaError(.fileWriteUnknown)}
            CGImageDestinationAddImage(dest,image,nil)
            guard CGImageDestinationFinalize(dest) else {throw CocoaError(.fileWriteUnknown)}
        }
    }
}
do {
    try renderPages(URL(fileURLWithPath:CommandLine.arguments[1]),directory:URL(fileURLWithPath:CommandLine.arguments[2]))
} catch { fputs("页面渲染失败\n",stderr);exit(1) }
