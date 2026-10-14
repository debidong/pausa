from PIL import Image, ImageFilter, ImageDraw
import numpy as np, random
random.seed(3); np.random.seed(3)
ic=Image.open('icon.png').convert('RGB'); W,H=2400,1000
a=np.array(ic).astype(float); cream=a[60:200,300:700].reshape(-1,3).mean(0)
def noise(sc,bl):
    m=np.random.rand(H//sc,W//sc); return np.array(Image.fromarray((m*255).astype('uint8')).resize((W,H),Image.BICUBIC).filter(ImageFilter.GaussianBlur(bl)))/255.
paper=cream+((noise(4,2)-.5)*10+(noise(1,.8)-.5)*8)[...,None]
yy,xx=np.mgrid[0:H,0:W]
wash=np.clip((noise(40,30)-.42)*2.2,0,1)*np.clip((yy/H-.3)*1.7,0,1)*np.clip(1.3-xx/W*1.2,.2,1)
water=np.array([170,184,180.])
out=paper*(1-wash[...,None]*.5)+water*wash[...,None]*.5
for i in range(10):
    y=random.randint(420,940); x0=random.randint(1200,1900); L=random.randint(200,450)
    s=np.zeros((H,W),'uint8'); s[y:y+3,x0:x0+L]=255
    s=np.array(Image.fromarray(s).filter(ImageFilter.GaussianBlur(6)))/255.*.3
    out=out*(1-s[...,None])+water*s[...,None]
canvas=Image.fromarray(np.clip(out,0,255).astype('uint8'))
R,G,B=a[...,0],a[...,1],a[...,2]
pink=np.clip((R-G-18)/25,0,1)
d=np.sqrt(((a-cream)**2).sum(-1))
green=np.clip((d-18)/35,0,1)*(1-np.clip((R-G-5)/15,0,1))
def feather(m,box,soft):
    x0,y0,x1,y1=box; f=Image.new('L',ic.size,0); ImageDraw.Draw(f).rounded_rectangle([x0+soft,y0+soft,x1-soft,y1-soft],radius=soft,fill=255)
    f=np.array(f.filter(ImageFilter.GaussianBlur(soft/2)))/255.
    return Image.fromarray((m*f*255).astype('uint8')).filter(ImageFilter.GaussianBlur(1.5)).crop(box), ic.crop(box)
lm,lot=feather(np.maximum(pink, green*.0),(70,140,945,800),30)
# lotus mask: dilate pink to include white petal highlights
lm=lm.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(3))
box=(612,716,1014,918); pad=ic.crop(box)
e=Image.new('L',pad.size,0); ImageDraw.Draw(e).ellipse([10,12,pad.width-8,pad.height-10],fill=255)
pm=e.filter(ImageFilter.GaussianBlur(8))
def paste(src,msk,x,y,s,al=1.,flip=False):
    if flip: src,msk=src.transpose(0),msk.transpose(0)
    sz=(int(src.width*s),int(src.height*s)); m=msk.resize(sz,Image.LANCZOS).point(lambda v:int(v*al))
    canvas.paste(src.resize(sz,Image.LANCZOS),(x,y),m)
paste(pad,pm,40,760,1.4,.9); paste(pad,pm,700,830,.9,.85,True); paste(pad,pm,900,650,.65,.75)
paste(pad,pm,-60,470,.8,.6,True); paste(pad,pm,520,560,.55,.6)
paste(lot,lm,110,120,1.0)
paste(lot,lm,860,560,.42,.95)
canvas.save('pond-light.png')
c=np.array(canvas).astype(float)/255.
dark=(c**1.8)*np.array([0.24,0.28,0.36])*255+np.array([8,11,18])
Image.fromarray(np.clip(dark,0,255).astype('uint8')).save('pond-dark.png')
