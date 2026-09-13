import AppKit
import WebKit
let args=CommandLine.arguments
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let outputArgument=args.count>1 ? args[1] : "frames"
let output=outputArgument.hasPrefix("/") ? URL(fileURLWithPath:outputArgument) : root.appendingPathComponent(outputArgument)
let video=output.pathExtension == "mp4"
let highPrecision=ProcessInfo.processInfo.environment["IDLESSE_FRAME_ENCODER"] == "x265"
try FileManager.default.createDirectory(at:video ? output.deletingLastPathComponent() : output,withIntermediateDirectories:true)
var encoder:Process?
var encoderPipe:Pipe?
if video {
 let p=Process(), pipe=Pipe()
 p.executableURL=URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg")
 // x265 at 10 bits keeps soft gradients -- a window glow under a dark tint --
 // smooth where the hardware encoder cuts them into contour bands and blocks.
 // It is several times slower, so it is chosen per run rather than assumed.
 let input=["-hide_banner","-loglevel","error","-y","-f","image2pipe","-framerate","60","-i","pipe:0","-an"]
 let hardware=["-c:v","hevc_videotoolbox","-b:v","40M","-pix_fmt","yuv420p","-color_range","tv","-colorspace","smpte170m"]
 let x265=["-vf","scale=out_color_matrix=bt709:out_range=full,format=yuv420p10le","-c:v","libx265","-preset","fast","-b:v","40M","-maxrate","60M","-bufsize","80M","-x265-params","log-level=error:aq-mode=3","-color_range","pc","-colorspace","bt709"]
 p.arguments=input+(highPrecision ? x265 : hardware)+["-color_primaries","bt709","-color_trc","iec61966-2-1","-tag:v","hvc1","-movflags","+faststart+write_colr",output.path]
 p.standardInput=pipe
 try p.run();encoder=p;encoderPipe=pipe
}
let count=args.count>2 ? Int(args[2])! : 1
let width=args.count>3 ? Int(args[3])! : 3840
let height=args.count>4 ? Int(args[4])! : 2160
let folder=args.count>5 ? args[5] : "assets/ch0069_home"
let stem=args.count>6 ? args[6] : "CH0069_home"
let animation=args.count>7 ? args[7] : "Idle_01"
let renderPort=Int(ProcessInfo.processInfo.environment["IDLESSE_RENDER_PORT"] ?? "18763") ?? 18763
let startTime=args.count>8 ? Double(args[8])! : 0
let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
class Driver:NSObject,WKNavigationDelegate {
 var index=0
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
  let js="return await window.prepare(folder,stem,width,height,animation);"
  webView.callAsyncJavaScript(js,arguments:["folder":folder,"stem":stem,"width":width,"height":height,"animation":animation],in:nil,in:.page){result in
   switch result {case .success(let value):
    if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {try? data.write(to:output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent+".json"))}
    print("Scene loaded; rendering \(count) frames at \(width)x\(height)");self.next(webView)
    case .failure(let error):fputs("\(error)\n",stderr);exit(1)}
  }
 }
 func next(_ webView:WKWebView) {
  if index>=count {
   try? encoderPipe?.fileHandleForWriting.close();encoder?.waitUntilExit()
   print("Completed \(index) frames");exit(encoder?.terminationStatus ?? 0)
  }
  // JPEG frames are quick for the hardware encoder; x265 gets lossless PNG so its precision is real.
  webView.evaluateJavaScript("window.frame(\(startTime+Double(index)/60),\(video && !highPrecision))"){value,error in
   guard error == nil,let text=value as? String,let data=Data(base64Encoded:text) else {fputs("Frame error \(String(describing:error))\n",stderr);exit(2)}
   do {
    if video {try encoderPipe!.fileHandleForWriting.write(contentsOf:data)}
    else {try data.write(to:output.appendingPathComponent(String(format:"%06d.png",self.index)))}
   }catch{exit(3)}
   self.index += 1
   if self.index % 60 == 0 {print("Frame \(self.index)");fflush(stdout)}
   self.next(webView)
  }
 }
}
let driver=Driver()
let webConfiguration=WKWebViewConfiguration()
webConfiguration.websiteDataStore = .nonPersistent()
let view=WKWebView(frame:NSRect(x:0,y:0,width:width,height:height),configuration:webConfiguration)
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
window.contentView=view
view.navigationDelegate=driver
view.load(URLRequest(url:URL(string:"http://127.0.0.1:\(renderPort)/index.html")!))
DispatchQueue.main.asyncAfter(deadline:.now()+(highPrecision ? 3600 : 600)){fputs("Export timeout\n",stderr);exit(4)}
app.run()
