import {Output,BufferTarget,CanvasSource,Mp4OutputFormat,canEncodeVideo} from 'mediabunny';
const MAIN10_CODEC='hvc1.2.4.L153.B0';
window.fastExport=async(folder,stem,animation,count,width,height,url,bitDepth=10)=>{
 if(!Number.isInteger(count)||count<1||count>5400||width!==3840||height!==2160)throw new Error("Export budget exceeded");
 if(bitDepth!==8&&bitDepth!==10)throw new Error("Export bit depth must be 8 or 10");
 const capability={width,height,bitrate:40000000,hardwareAcceleration:'prefer-hardware'};
 const encoding={codec:'hevc',bitrate:40000000,hardwareAcceleration:'prefer-hardware'};
 if(bitDepth===10){capability.fullCodecString=MAIN10_CODEC;encoding.fullCodecString=MAIN10_CODEC;}
 if(!await canEncodeVideo('hevc',capability))throw new Error(bitDepth===10?'HEVC Main10 WebCodecs encoding is unavailable':'HEVC WebCodecs encoding is unavailable');
 const meta=await window.prepare(folder,stem,width,height,animation);
 const started=performance.now();
 const output=new Output({format:new Mp4OutputFormat({fastStart:'in-memory'}),target:new BufferTarget()});
 let encoderCodec=null;
 encoding.onEncoderConfig=config=>{encoderCodec=config.codec??null;};
 const source=new CanvasSource(document.querySelector('canvas'),encoding);
 output.addVideoTrack(source,{frameRate:60});await output.start();
 for(let i=0;i<count;i++) {window.frame(i/60,'draw');await source.add(i/60,1/60);if((i+1)%60===0)window.webkit?.messageHandlers?.progress?.postMessage([i+1,count]);}
 await output.finalize();
 const response=await fetch(url,{method:'POST',body:output.target.buffer});if(!response.ok)throw new Error('Output write rejected');
 return {...meta,frames:count,encodeSeconds:(performance.now()-started)/1000,bytes:output.target.buffer.byteLength,requestedBitDepth:bitDepth,encoderCodec};
};
// Lossless frames for x265: raw pixels straight off the canvas, one POST each, so
// nothing is PNG-compressed, base64-encoded and decoded again on the way. Each
// POST waits for the host to hand the frame to the encoder, which paces the loop.
// `first` renders a slice of a longer loop, so several pages can split one export.
window.rawExport=async(folder,stem,animation,count,width,height,url,first=0)=>{
 if(!Number.isInteger(count)||count<1||count>5400||width!==3840||height!==2160)throw new Error("Export budget exceeded");
 const meta=await window.prepare(folder,stem,width,height,animation);
 const gl=document.querySelector('canvas').getContext('webgl2')??document.querySelector('canvas').getContext('webgl');
 const pixels=new Uint8Array(width*height*4);
 const started=performance.now();
 const spent={draw:0,read:0,send:0};
 for(let i=0;i<count;i++){
  let t=performance.now();
  window.frame((first+i)/60,'draw');
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