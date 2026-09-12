import * as PIXI from 'pixi.js';
import {Live2DModel} from 'pixi-live2d-display/cubism4';
window.PIXI=PIXI;
let app,model,last=0,ambient=null;

// A motion3 curve is piecewise: linear, cubic bezier, stepped or inverse-stepped.
// Bezier segments are parameterised by control points rather than by time, so the
// parameter that lands on the wanted time is found by bisection, as Cubism does.
const bezierAt=(p,time)=>{
 const x=s=>{const u=1-s;return u*u*u*p[0]+3*u*u*s*p[2]+3*u*s*s*p[4]+s*s*s*p[6];};
 const y=s=>{const u=1-s;return u*u*u*p[1]+3*u*u*s*p[3]+3*u*s*s*p[5]+s*s*s*p[7];};
 let lo=0,hi=1;
 for(let k=0;k<24;k++){const m=(lo+hi)/2;if(x(m)<time)lo=m;else hi=m;}
 return y((lo+hi)/2);
};
const curveAt=(seg,time)=>{
 let t0=seg[0],v0=seg[1],i=2;
 while(i<seg.length){
  if(seg[i]===1){
   const t3=seg[i+5],v3=seg[i+6];
   if(time<=t3)return bezierAt([t0,v0,seg[i+1],seg[i+2],seg[i+3],seg[i+4],t3,v3],time);
   t0=t3;v0=v3;i+=7;
  }else{
   const type=seg[i],t1=seg[i+1],v1=seg[i+2];
   if(time<=t1){
    if(type===0)return v0+(v1-v0)*(t1===t0?1:(time-t0)/(t1-t0));
    return type===2?v0:v1;
   }
   t0=t1;v0=v1;i+=3;
  }
 }
 return v0;
};
window.prepare=async(folder,stem,width,height,animation='idle')=>{
 app=new PIXI.Application({width,height,resolution:1,antialias:true,backgroundColor:0x18202b,preserveDrawingBuffer:true,autoStart:false});document.body.appendChild(app.view);
 const url=`${folder}/${stem}.model3.json`;
 model=await Live2DModel.from(url,{autoUpdate:false,autoInteract:false,idleMotionGroup:animation,motionPreload:'NONE'});
 const catalog=await(await fetch('catalog.json')).json();const entry=catalog[stem];
 if(entry?.bg){const texture=await PIXI.Texture.fromURL(`backgrounds/${entry.bg}.png`);const bg=new PIXI.Sprite(texture);bg.anchor.set(.5);bg.position.set(width/2,height/2);bg.scale.set(Math.max(width/texture.width,height/texture.height));app.stage.addChild(bg);}
 app.stage.addChild(model);model.anchor.set(.5,.5);model.position.set(width/2,height/2);
 const configs=await(await fetch('viewer-configs.json')).json();const cfg=configs[stem]??{},factor=height/1080,scale=cfg.newMainScale??1,offset=cfg.offset??[0,0],extra=cfg.newMainOffset??[0,-10];
 model.scale.set((cfg.scale??52)*scale/model.internalModel.pixelsPerUnit*factor);
 model.position.set(width/2+(extra[0]+offset[0]*scale)*factor,height/2-(extra[1]+offset[1]*scale)*factor);
 const cameras=await(await fetch('cameras.json')).json(),zoom=cameras[stem]??1;
 model.scale.set(model.scale.x*zoom);model.position.set(width/2+(model.x-width/2)*zoom,height/2+(model.y-height/2)*zoom);
 if(stem==='yingxianzuo_3')model.y+=height*.10;
 model.elapsedTime=0;model.internalModel.breath=undefined;model.internalModel.eyeBlink=undefined;
 const motion=await model.internalModel.motionManager.loadMotion(animation,0);if(!motion)throw Error('Missing idle motion');
 motion.setIsLoop(true);motion.setFadeInTime(0);motion.setFadeOutTime(0);motion.setIsLoopFadeIn(false);
 await model.motion(animation,0,3);
 // Advance stateful physics at a fixed cadence, including rendering updates.
 const settings=await(await fetch(url)).json();const motionMeta=await(await fetch(`${folder}/${settings.FileReferences.Motions[animation][0].File}`)).json();
 // Scene ambience (falling petals, flowing water, foliage, the view out of the
 // window) is authored in its own motion group. Only the idle was ever played, so
 // that layer sat frozen in every export. Its parameters are disjoint from the
 // idle's, so it can be applied alongside; it is retimed to complete exactly one
 // cycle per idle loop, which makes one export length loop both instead of needing
 // their lowest common multiple. The retime is recorded in the returned metadata.
 const ambientGroup=Object.keys(settings.FileReferences.Motions).find(g=>g!==animation&&/effect|ambient/i.test(g));
 if(ambientGroup){
  const file=settings.FileReferences.Motions[ambientGroup][0].File;
  const data=await(await fetch(`${folder}/${file}`)).json();
  const idleParams=new Set(motionMeta.Curves.filter(c=>c.Target==='Parameter').map(c=>c.Id));
  const curves=data.Curves.filter(c=>c.Target==='Parameter'&&!idleParams.has(c.Id)).map(c=>({id:c.Id,seg:c.Segments}));
  if(curves.length)ambient={group:ambientGroup,curves,duration:data.Meta.Duration,
   rate:data.Meta.Duration/motionMeta.Meta.Duration,skipped:data.Curves.filter(c=>c.Target==='Parameter'&&idleParams.has(c.Id)).map(c=>c.Id)};
 }
 for(let i=0;i<Math.round(motionMeta.Meta.Duration*60)*3;i++){model.update(1000/60);app.renderer.render(app.stage);}
 last=0;
 // The idle motion owns the model's own parameters; these belong to nobody else,
 // so they are written straight onto the core model after each update and before
 // the draw. Retimed by `rate` so one ambient cycle spans one idle loop.
 const applyAmbient=time=>{
  if(!ambient)return;
  const core=model.internalModel.coreModel,at=(time*ambient.rate)%ambient.duration;
  for(const c of ambient.curves)core.setParameterValueById(c.id,curveAt(c.seg,at));
 };
 window.frame=(time,fast=false)=>{
  if(time<last)throw Error('Live2D export requires monotonic time');
  for(let t=last;t<time-1e-7;t+=1/60){model.update(Math.min(1/60,time-t)*1000);applyAmbient(Math.min(t+1/60,time));app.renderer.render(app.stage);}
  applyAmbient(time);app.renderer.render(app.stage);last=time;
  if(fast==='draw'){app.renderer.gl.finish();return null;}
  return app.view.toDataURL(fast?'image/jpeg':'image/png',.99).split(',')[1];
 };
 return {animations:[{name:animation,duration:motionMeta.Meta.Duration}],width:model.internalModel.width,height:model.internalModel.height,pixelsPerUnit:model.internalModel.pixelsPerUnit,physics:!!model.internalModel.physics,
  ambient:ambient&&{group:ambient.group,parameters:ambient.curves.length,authoredDuration:ambient.duration,retimedBy:Number(ambient.rate.toFixed(4)),skippedSharedParameters:ambient.skipped}};
};
