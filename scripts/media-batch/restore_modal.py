import modal
from pathlib import Path
import json
import time
app=modal.App("idlesse-media-batch")
image=modal.Image.debian_slim(python_version="3.11").pip_install("torch==2.7.1","numpy","Pillow").apt_install("ffmpeg")
@app.function(image=image,gpu="L4",timeout=900,retries=0,max_containers=1,cpu=8,memory=16384,scaledown_window=2)
def bench(textures: bytes):
 import torch,numpy as np,time,io,urllib.request
 from PIL import Image
 from torch import nn
 from torch.nn import functional as F
 class Net(nn.Module):
  def __init__(self):
   super().__init__();self.body=nn.ModuleList([nn.Conv2d(3,64,3,1,1),nn.PReLU(64)])
   for _ in range(16):self.body.extend([nn.Conv2d(64,64,3,1,1),nn.PReLU(64)])
   self.body.append(nn.Conv2d(64,48,3,1,1));self.upsampler=nn.PixelShuffle(4)
  def forward(self,x):
   y=x
   for layer in self.body:y=layer(y)
   return self.upsampler(y)+F.interpolate(x,scale_factor=4,mode="nearest")
 url="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth"
 urllib.request.urlretrieve(url,"/tmp/weights.pth")
 model=Net();weights=torch.load("/tmp/weights.pth",map_location="cpu",weights_only=True);model.load_state_dict(weights.get("params_ema",weights.get("params",weights)))
 model=model.eval().cuda().half().to(memory_format=torch.channels_last)
 wall=time.monotonic()
 import zipfile
 assetsOut=io.BytesIO();textureReports=[]
 if textures:
  torch.backends.cudnn.benchmark=False
  with zipfile.ZipFile(io.BytesIO(textures)) as zin, zipfile.ZipFile(assetsOut,"w",compression=zipfile.ZIP_STORED) as zout, torch.inference_mode():
   for entry in zin.infolist():
    if not entry.filename.endswith(".png"):continue
    stamp=time.monotonic();original=Image.open(io.BytesIO(zin.read(entry))).convert("RGBA");ow,oh=original.size
    arr=np.array(original.convert("RGB")).astype(np.float32)/255
    tx=torch.from_numpy(arr).permute(2,0,1).unsqueeze(0).cuda().half().contiguous(memory_format=torch.channels_last)
    ty=model(tx)
    pixels=ty[0].clamp(0,1).mul(255).to(torch.uint8).permute(1,2,0).contiguous().cpu().numpy()
    result=Image.fromarray(pixels).resize((ow*2,oh*2),Image.Resampling.LANCZOS)
    result.putalpha(original.getchannel("A").resize(result.size,Image.Resampling.LANCZOS))
    buf=io.BytesIO();result.save(buf,format="PNG",compress_level=3);zout.writestr(entry.filename,buf.getvalue())
    textureReports.append({"file":entry.filename,"size":list(result.size),"seconds":time.monotonic()-stamp});print(textureReports[-1],flush=True)
    del tx,ty,pixels,arr,result
 return {"textures":textureReports,"seconds":time.monotonic()-wall},assetsOut.getvalue()

@app.local_entrypoint()
def main(input_path: str, output_path: str):
 report,data=bench.remote(Path(input_path).read_bytes())
 Path(output_path).write_bytes(data)
 Path(output_path+'.json').write_text(json.dumps(report,indent=2))
 print(json.dumps(report))
