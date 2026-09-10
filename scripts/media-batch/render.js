import * as PIXI from 'pixi.js';
import {TextureAtlas} from '@pixi-spine/base';
import {Spine, SkeletonBinary, AtlasAttachmentLoader} from '@pixi-spine/runtime-3.8';
import {Spine as Spine42} from '@esotericsoftware/spine-pixi-v7';
let app, model;
window.prepare = async (folder, stem, width, height, animation) => {
  app = new PIXI.Application({width,height,resolution:1,antialias:true,backgroundColor:0x000000,preserveDrawingBuffer:true,autoStart:false});
  document.body.appendChild(app.view);
  const bytes=new Uint8Array(await(await fetch(`${folder}/${stem}.skel`)).arrayBuffer());
  let data;
  if(new TextDecoder().decode(bytes.slice(0,30)).includes('4.2.')) {
    await PIXI.Assets.load([`${folder}/${stem}.atlas`,`${folder}/${stem}.skel`]);
    model=Spine42.from({skeleton:`${folder}/${stem}.skel`,atlas:`${folder}/${stem}.atlas`,autoUpdate:false});
    data=model.skeleton.data;
  } else {
  const text = await (await fetch(`${folder}/${stem}.atlas`)).text();
  const atlas = await new Promise(resolve=>new TextureAtlas(text,(name,done)=>{
    const tex=PIXI.BaseTexture.from(`${folder}/${name}`);
    if(tex.valid) done(tex); else tex.once('loaded',()=>done(tex));
  },resolve));
  data=new SkeletonBinary(new AtlasAttachmentLoader(atlas)).readSkeletonData(bytes);
  model=new Spine(data);model.autoUpdate=false;
  }
  app.stage.addChild(model);
  model.state.setAnimation(0,animation,true);model.update(0);
  const bounds=model.getLocalBounds();
  const scale=Math.max(width/bounds.width,height/bounds.height);
  model.scale.set(scale);model.position.set(width/2-(bounds.x+bounds.width/2)*scale,height/2-(bounds.y+bounds.height/2)*scale);
  // Per-lobby camera crop: authoring sheets can hold unused poses outside the live scene.
  const cameras={CH0222_home:[1.10,0.50,0.50],CH0233_home:[1.9,0.37,0.66],CH0230_home:[1.6,0.47,0.52],CH0335_home:[1.4,0.405,0.415],CH0071_home:[1.12,0.50,0.50],CH0282_home:[1.2,0.547,0.50],CH0198_home:[2.0,0.90,0.46],CH0167_home:[1.8,0.294,0.46],CH0100_home:[1.85,0.80,0.56]};
  const camera=cameras[stem];
  if(camera){
    const [zoom,cx,cy]=camera;
    model.position.set(width/2+(model.x-width*cx)*zoom,height/2+(model.y-height*cy)*zoom);
    model.scale.set(scale*zoom);
  }
  window.frame = (time,fast=false) => {
    model.skeleton.setToSetupPose();
    model.state.clearTracks();
    const track=model.state.setAnimation(0,animation,true);track.trackTime=time;
    model.update(0);
    // Export adaptation: Unity lobby lighting tracks are not present in Spine alone.
    if(stem==="CH0239_home") for(const slot of model.skeleton.slots) if(slot.data.blendMode===1) slot.color.a *= 0.15;
    app.renderer.render(app.stage);
    return app.view.toDataURL(fast?'image/jpeg':'image/png',0.99).split(',')[1];
  };
  return {slots:model.skeleton.slots.filter(s=>s.data.blendMode!==0).map(s=>({name:s.data.name,blend:s.data.blendMode,alpha:s.color.a,attachment:s.getAttachment()?.name})),bounds:{x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height},scale,animations:data.animations.map(a=>({name:a.name,duration:a.duration}))};
};
