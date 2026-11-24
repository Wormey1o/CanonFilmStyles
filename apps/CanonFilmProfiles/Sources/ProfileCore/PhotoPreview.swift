import Foundation
import ImageIO
import UniformTypeIdentifiers
import FilmProfileEngine

/// Immutable input. A CR2 uses the same as-shot embedded JPEG as the camera runtime.
public struct PhotoPreviewSource: Sendable {
 public let jpeg:Data
 public let orientation:UInt32
 public let name:String
 public let isCameraInput:Bool
 public init(jpeg:Data,orientation:UInt32=1,name:String="Canon test photo",isCameraInput:Bool=true)throws {
  guard jpeg.count<=16_777_216,[1,3,6,8].contains(orientation),let image=CGImageSourceCreateWithData(jpeg as CFData,nil),let props=CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],(props[kCGImagePropertyPixelWidth] as? Int)==2256,(props[kCGImagePropertyPixelHeight] as? Int)==1504 else {throw ProfileError.invalid("Preview requires a 2256 × 1504 JPEG.")}
  self.jpeg=jpeg;self.orientation=orientation;self.name=name;self.isCameraInput=isCameraInput
 }
 public static func load(_ url:URL)throws->Self {
  let count=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
  guard count>0,count<=67_108_864 else{throw ProfileError.invalid("Choose a photo smaller than 64 MB.")}
  let data=try Data(contentsOf:url,options:.mappedIfSafe)
  guard data.count<=67_108_864 else{throw ProfileError.invalid("Photo is too large.")}
  if url.pathExtension.lowercased()=="cr2" {
   var offset:UInt32=0,length:UInt32=0,orientation:UInt32=0
   let rc=data.withUnsafeBytes{cfp_preview_extract($0.bindMemory(to:UInt8.self).baseAddress,data.count,&offset,&length,&orientation)}
   guard rc==0 else{throw ProfileError.invalid("This CR2 has no supported EOS 450D sRGB preview. Choose a JPEG instead.")}
   return try Self(jpeg:data.subdata(in:Int(offset)..<Int(offset+length)),orientation:orientation,name:url.lastPathComponent)
  }
  guard let source=CGImageSourceCreateWithData(data as CFData,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=props[kCGImagePropertyPixelWidth] as? Int,let h=props[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,w<=12000,h<=12000,w*h<=40_000_000 else{throw ProfileError.invalid("This photo could not be read. Choose a JPEG or EOS 450D CR2.")}
  // Standalone JPEGs are normalised into sRGB; they are an approximation of RAW's embedded preview.
  guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2256] as CFDictionary),let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:2256,height:1504,bitsPerComponent:8,bytesPerRow:2256*4,space:space,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{throw ProfileError.invalid("Unable to prepare this photo.")}
  context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:0,y:0,width:2256,height:1504))
  let scale=min(2256/Double(image.width),1504/Double(image.height)),width=Double(image.width)*scale,height=Double(image.height)*scale
  context.interpolationQuality = .high;context.draw(image,in:CGRect(x:(2256-width)/2,y:(1504-height)/2,width:width,height:height))
  // The camera decoder deliberately rejects restart markers and progressive JPEGs.
  // Use its paired baseline encoder instead of ImageIO's system-selected JPEG variant.
  guard let pixels=context.data else{throw ProfileError.invalid("Unable to prepare this photo.")}
  var output=Data(count:1_310_720),written=0
  let rc=output.withUnsafeMutableBytes{o in cfp_preview_prepare_rgba(pixels.assumingMemoryBound(to:UInt8.self),o.bindMemory(to:UInt8.self).baseAddress,o.count,&written)}
  guard rc==0 else{throw ProfileError.invalid("Unable to prepare this JPEG (\(rc)). Choose a less detailed photo or a CR2.")}
  output.count=written
  return try Self(jpeg:output,name:url.lastPathComponent,isCameraInput:false)
 }
}

public final class PhotoPreviewCancellation: @unchecked Sendable {
 fileprivate let pointer:UnsafeMutableRawPointer
 public init()throws{guard let p=cfp_preview_token() else{throw ProfileError.invalid("Not enough memory for preview.")};pointer=p}
 public func cancel(){cfp_preview_cancel(pointer)}
 deinit{cfp_preview_token_free(pointer)}
}

/// Serialises render jobs; the host bridge protects shared lookup initialisation.
public actor PhotoPreviewRenderer {
 public static let shared=PhotoPreviewRenderer()
 public func render(_ source:PhotoPreviewSource,profile:CompiledProfile,cancellation:PhotoPreviewCancellation)throws->Data {
  try renderBody(source,body:profile.body,shading:profile.recipe.shading,sharpness:profile.recipe.sharpness,clarity:profile.recipe.clarity,mixer:profile.recipe.effectiveBWFilter?.enabled == true,cancellation:cancellation)
 }
 public func renderBody(_ source:PhotoPreviewSource,body:Data,shading:Int,sharpness:Int,clarity:Int,mixer:Bool,cancellation:PhotoPreviewCancellation)throws->Data {
  try ProfileCompiler.validateBody(body,mixerEnabled:mixer)
  guard (-4...4).contains(shading),(-4...4).contains(sharpness),(-4...4).contains(clarity) else{throw ProfileError.invalid("Invalid preview controls.")}
  var output=Data(count:1_310_720),written=0
  let rc=body.withUnsafeBytes{b in source.jpeg.withUnsafeBytes{j in output.withUnsafeMutableBytes{o in cfp_preview_jpeg(b.bindMemory(to:UInt8.self).baseAddress,j.bindMemory(to:UInt8.self).baseAddress,source.jpeg.count,source.orientation,Int32(shading),Int32(sharpness),Int32(clarity),mixer ? 1:0,o.bindMemory(to:UInt8.self).baseAddress,o.count,&written,cancellation.pointer)}}}
  guard rc==0 else{throw ProfileError.invalid(rc == -6 ? "Preview cancelled.":"This photo could not be rendered (\(rc)). Choose another photo.")}
  output.count=written;return output
 }
}
