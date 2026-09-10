import * as PIXI from 'pixi.js';
import {Live2DModel} from 'pixi-live2d-display/cubism4';
window.PIXI=PIXI;
let app,model,last=0;
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
 for(let i=0;i<Math.round(motionMeta.Meta.Duration*60)*3;i++){model.update(1000/60);app.renderer.render(app.stage);}
 last=0;
 window.frame=(time,fast=false)=>{
  if(time<last)throw Error('Live2D export requires monotonic time');
  for(let t=last;t<time-1e-7;t+=1/60){model.update(Math.min(1/60,time-t)*1000);app.renderer.render(app.stage);}
  app.renderer.render(app.stage);last=time;
  if(fast==='draw'){app.renderer.gl.finish();return null;}
  return app.view.toDataURL(fast?'image/jpeg':'image/png',.99).split(',')[1];
 };
 return {animations:[{name:animation,duration:motionMeta.Meta.Duration}],width:model.internalModel.width,height:model.internalModel.height,pixelsPerUnit:model.internalModel.pixelsPerUnit,physics:!!model.internalModel.physics};
};
