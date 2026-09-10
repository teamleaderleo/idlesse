import AppKit
import WebKit
let args=CommandLine.arguments
let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
let activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Exporting wallpaper")
var lastProgress=Date()
let exportStarted=Date()
let code=try String(contentsOfFile:args[2],encoding:.utf8)
class Driver:NSObject,WKNavigationDelegate,WKScriptMessageHandler {
 func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
  if let values=message.body as? [Int],values.count==2 {lastProgress=Date();print("Frame \(values[0])/\(values[1])");fflush(stdout)}
 }
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
  webView.callAsyncJavaScript(code,arguments:[:],in:nil,in:.page){result in
   switch result {case .success(let value):
    if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:args[3]))}
    print("Completed");exit(0)
    case .failure(let error):fputs("\(error)\n",stderr);exit(1)}
  }
 }
}
let driver=Driver();let cfg=WKWebViewConfiguration();cfg.websiteDataStore = .nonPersistent();cfg.userContentController.add(driver,name:"progress")
let view=WKWebView(frame:NSRect(x:0,y:0,width:3840,height:2160),configuration:cfg)
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view;view.navigationDelegate=driver
view.load(URLRequest(url:URL(string:args[1])!))
let watchdog=Timer.scheduledTimer(withTimeInterval:10,repeats:true){_ in
 if Date().timeIntervalSince(lastProgress)>120 || Date().timeIntervalSince(exportStarted)>1800 {fputs("Encoder progress timeout\n",stderr);exit(4)}
}
app.run()
