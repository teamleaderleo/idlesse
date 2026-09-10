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
