import {Output,BufferTarget,CanvasSource,Mp4OutputFormat} from 'mediabunny';
window.fastExport=async(folder,stem,animation,count,width,height,url)=>{
 if(!Number.isInteger(count)||count<1||count>5400||width!==3840||height!==2160)throw new Error("Export budget exceeded");
 const meta=await window.prepare(folder,stem,width,height,animation);
 const started=performance.now();
 const output=new Output({format:new Mp4OutputFormat({fastStart:'in-memory'}),target:new BufferTarget()});
 const source=new CanvasSource(document.querySelector('canvas'),{codec:'hevc',bitrate:40000000,hardwareAcceleration:'prefer-hardware'});
 output.addVideoTrack(source,{frameRate:60});await output.start();
 for(let i=0;i<count;i++) {window.frame(i/60,'draw');await source.add(i/60,1/60);if((i+1)%60===0)window.webkit?.messageHandlers?.progress?.postMessage([i+1,count]);}
 await output.finalize();
 const response=await fetch(url,{method:'POST',body:output.target.buffer});if(!response.ok)throw new Error('Output write rejected');
 return {...meta,frames:count,encodeSeconds:(performance.now()-started)/1000,bytes:output.target.buffer.byteLength};
};
// Lossless frames for x265: raw pixels straight off the canvas, one POST each, so
// nothing is PNG-compressed, base64-encoded and decoded again on the way. Each
// POST waits for the host to hand the frame to the encoder, which paces the loop.
window.rawExport=async(folder,stem,animation,count,width,height,url)=>{
 if(!Number.isInteger(count)||count<1||count>5400||width!==3840||height!==2160)throw new Error("Export budget exceeded");
 const meta=await window.prepare(folder,stem,width,height,animation);
 const gl=document.querySelector('canvas').getContext('webgl2')??document.querySelector('canvas').getContext('webgl');
 const pixels=new Uint8Array(width*height*4);
 const started=performance.now();
 const spent={draw:0,read:0,send:0};
 for(let i=0;i<count;i++){
  let t=performance.now();
  window.frame(i/60,'draw');
  spent.draw+=performance.now()-t;t=performance.now();
  gl.readPixels(0,0,width,height,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
  spent.read+=performance.now()-t;t=performance.now();
  const response=await fetch(`${url}/${i}`,{method:'POST',body:pixels});
  spent.send+=performance.now()-t;
  if(!response.ok)throw new Error('Frame write rejected');
  // Report often: on a busy Mac x265 can take over a minute for 60 frames, and the host gives up after 120 seconds of silence.
  if((i+1)%5===0||i+1===count)window.webkit?.messageHandlers?.progress?.postMessage([i+1,count]);
 }
 return {...meta,frames:count,encodeSeconds:(performance.now()-started)/1000,stageSeconds:Object.fromEntries(Object.entries(spent).map(([k,v])=>[k,v/1000]))};
};
