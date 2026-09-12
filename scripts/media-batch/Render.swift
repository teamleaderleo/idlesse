import AppKit
import WebKit
let args=CommandLine.arguments
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let outputArgument=args.count>1 ? args[1] : "frames"
let output=outputArgument.hasPrefix("/") ? URL(fileURLWithPath:outputArgument) : root.appendingPathComponent(outputArgument)
let video=output.pathExtension == "mp4"
let bitDepth=Int(ProcessInfo.processInfo.environment["IDLESSE_EXPORT_BIT_DEPTH"] ?? "10") ?? 10
guard bitDepth == 8 || bitDepth == 10 else { fputs("IDLESSE_EXPORT_BIT_DEPTH must be 8 or 10\n",stderr);exit(5) }
try FileManager.default.createDirectory(at:video ? output.deletingLastPathComponent() : output,withIntermediateDirectories:true)
var encoder:Process?
var encoderPipe:Pipe?
if video {
 let p=Process(), pipe=Pipe()
 p.executableURL=URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg")
 var codecArgs=["-hide_banner","-loglevel","error","-y","-f","image2pipe","-framerate","60","-i","pipe:0","-an","-c:v","hevc_videotoolbox","-b:v","40M","-pix_fmt",bitDepth == 10 ? "yuv420p10le" : "yuv420p"]
 if bitDepth == 10 { codecArgs += ["-profile:v","main10"] }
 codecArgs += ["-tag:v","hvc1","-movflags","+faststart",output.path]
 p.arguments=codecArgs
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
    var metadata=(value as? [String:Any]) ?? [:]
    metadata["requestedBitDepth"]=bitDepth
    metadata["encoder"]="frames"
    if let data=try? JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]) {try? data.write(to:output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent+".json"))}
    print("Scene loaded; rendering \(count) frames at \(width)x\(height), \(bitDepth)-bit HEVC");self.next(webView)
    case .failure(let error):fputs("\(error)\n",stderr);exit(1)}
  }
 }
 func next(_ webView:WKWebView) {
  if index>=count {
   try? encoderPipe?.fileHandleForWriting.close();encoder?.waitUntilExit()
   print("Completed \(index) frames");exit(encoder?.terminationStatus ?? 0)
  }
  let mode = video ? "'pipe-png'" : "false"
  webView.evaluateJavaScript("window.frame(\(startTime+Double(index)/60),\(mode))"){value,error in
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
DispatchQueue.main.asyncAfter(deadline:.now()+600){fputs("Export timeout\n",stderr);exit(4)}
app.run()
