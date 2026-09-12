import cameraRecipes from './cameras.json';
import * as PIXI from 'pixi.js';
import {TextureAtlas} from '@pixi-spine/base';
import {Spine,SkeletonBinary,AtlasAttachmentLoader} from '@pixi-spine/runtime-3.8';
window.prepare=async(folder,stem,width,height,animation='normal')=>{
 const app=new PIXI.Application({width,height,resolution:1,antialias:true,backgroundColor:0x18202b,preserveDrawingBuffer:true,autoStart:false});document.body.appendChild(app.view);
 const descriptor=await(await fetch(`${folder}/model.json`)).json();const container=new PIXI.Container();const models=[];
 for(const layer of descriptor.layers){
  const bytes=new Uint8Array(await(await fetch(`${folder}/${layer.skel}`)).arrayBuffer());const atlasText=await(await fetch(`${folder}/${layer.atlas}`)).text();
  const pages={};for(const page of layer.textures)pages[page]=await PIXI.Assets.load(`${folder}/${page}`);
  const atlas=new TextureAtlas(atlasText,(name,done)=>done(pages[name].baseTexture));const data=new SkeletonBinary(new AtlasAttachmentLoader(atlas)).readSkeletonData(bytes);
  const model=new Spine(data);model.autoUpdate=false;if(data.findSkin(layer.initialSkin))model.skeleton.setSkinByName(layer.initialSkin);model.skeleton.setSlotsToSetupPose();model.state.setAnimation(0,animation,true);model.update(0);container.addChild(model);models.push(model);
 }
 app.stage.addChild(container);const b=container.getLocalBounds();
 // Bounds cover the whole skeleton, transparent effect padding included, so fitting
 // them alone strands character-only models in the background colour. A recipe is
 // [zoom, centreX, centreY] in frame fractions, and is read from the posed skeleton,
 // so it only frames the animation it was calibrated on; an entry may map animation
 // names to recipes with `default` covering the rest.
 const recipe=cameraRecipes[stem];
 const camera=Array.isArray(recipe)?recipe:recipe?.[animation]??recipe?.default??null;
 const fit=Math.min(width/b.width,height/b.height);
 container.scale.set(fit);container.position.set(width/2-(b.x+b.width/2)*fit,height/2-(b.y+b.height/2)*fit);
 if(camera){const [zoom,cx,cy]=camera;
  container.position.set(width/2+(container.x-width*cx)*zoom,height/2+(container.y-height*cy)*zoom);
  container.scale.set(fit*zoom);}
 window.frame=(time,fast=false)=>{for(const m of models){m.skeleton.setToSetupPose();m.state.clearTracks();m.state.setAnimation(0,animation,true).trackTime=time;m.update(0);}app.renderer.render(app.stage);if(fast==='draw'){app.renderer.gl.finish();return null;}return app.view.toDataURL(fast?'image/jpeg':'image/png',.99).split(',')[1];};
 return {camera,animations:models[descriptor.mainLayer??0].spineData.animations.map(a=>({name:a.name,duration:a.duration})),layerAnimations:models.map(m=>m.spineData.animations.map(a=>({name:a.name,duration:a.duration}))),bounds:b};
};
