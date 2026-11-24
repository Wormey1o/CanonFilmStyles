/* SPDX-License-Identifier: GPL-2.0-or-later
 * Bounded integer spatial controls on graded RGB, before film grain.
 * RGB delay rows stay immutable: fine-filter neighbours never see an earlier
 * output's sharpening, clarity, shading or grain. Frame edges replicate. */
#include "detail.h"
#include "se_libc.h"
struct se_detail_run {
 int w,h,r,nring,ndelay,pushed,seen,ended,sharp,clarity;
 uint8_t *rgb,*mean,*output;
 uint16_t *columns;
};
static int luma(const uint8_t *p){return (77*p[0]+150*p[1]+29*p[2])>>8;}
static int edge(int x,int w){return x<0?0:x>=w?w-1:x;}
static uint8_t clip(int x){return (uint8_t)(x<0?0:x>255?255:x);}
se_err se_detail_begin(se_detail_run **out,const se_detail *v,int w,int h,se_arena *ar){
 if(!out || !v || !ar || w<1 || w>4096 || h<1 || h>4096 || v->shading<-4 || v->shading>4 || v->sharpness<-4 || v->sharpness>4 || v->clarity<-4 || v->clarity>4)return SE_E_CORRUPT;
 *out=0;if(!v->sharpness && !v->clarity)return SE_OK;
 se_detail_run *s=SE_NEW(ar,se_detail_run,1);if(!s)return SE_E_NOMEM;memset(s,0,sizeof *s);
 s->w=w;s->h=h;s->r=v->clarity?8:1;s->nring=2*s->r+1;s->ndelay=s->r+2;s->sharp=v->sharpness;s->clarity=v->clarity;
 s->rgb=SE_NEW(ar,uint8_t,(size_t)s->ndelay*w*3);s->output=SE_NEW(ar,uint8_t,(size_t)w*3);
 if(!s->rgb || !s->output)return SE_E_NOMEM;
 if(s->clarity){s->mean=SE_NEW(ar,uint8_t,(size_t)s->nring*w);s->columns=SE_NEW(ar,uint16_t,w);if(!s->mean || !s->columns)return SE_E_NOMEM;memset(s->columns,0,(size_t)w*2);}
 *out=s;return SE_OK;
}
static se_err push(se_detail_run *s,const uint8_t *src,se_detail_emit emit,void *ctx){
 int w=s->w,p=s->pushed,slot=p%s->ndelay;
 memcpy(s->rgb+(size_t)slot*w*3,src,(size_t)w*3);
 if(s->clarity){
  uint8_t *row=s->mean+(size_t)(p%s->nring)*w,taps[17];int sum=0,head=0;
  for(int k=0;k<17;k++)sum+=(taps[k]=(uint8_t)luma(src+3*edge(k-8,w)));
  for(int x=0;x<w;x++){
   if(p>=s->nring)s->columns[x]-=row[x];
   row[x]=(uint8_t)((sum+8)/17);s->columns[x]+=row[x];
   int next=luma(src+3*edge(x+9,w));
   sum+=next-taps[head];taps[head]=(uint8_t)next;if(++head==17)head=0;
  }
 }
 s->pushed++;if(p<2*s->r)return SE_OK;
 int centre=p-s->r,y=p-2*s->r;
 const uint8_t *mid=s->rgb+(size_t)(centre%s->ndelay)*w*3;
 const uint8_t *above=s->rgb+(size_t)((y?centre-1:centre)%s->ndelay)*w*3;
 const uint8_t *below=s->rgb+(size_t)((y+1<s->h?centre+1:centre)%s->ndelay)*w*3;
 int left=0,centre_sum=0;
 if(s->sharp){
  centre_sum=luma(above)+luma(mid)+luma(below);
  left=centre_sum;
 }
 for(int x=0;x<w;x++){
  int lum=luma(mid+3*x),delta=0;
  if(s->sharp){
   int k=3*edge(x+1,w);
   int right=luma(above+k)+luma(mid+k)+luma(below+k);
   int high=lum-(left+centre_sum+right+4)/9;
   delta+=s->sharp*high/4;
   left=centre_sum;
   centre_sum=right;
  }
  if(s->clarity){int base=(s->columns[x]+8)/17;int weight=2*(lum<128?lum:255-lum);delta+=s->clarity*(lum-base)*weight/2048;}
  for(int c=0;c<3;c++)s->output[3*x+c]=clip(mid[3*x+c]+delta);
 }
 return emit(ctx,s->output,w)==0?SE_OK:SE_E_IO;
}
se_err se_detail_rows(se_detail_run *s,const uint8_t *rgb,int n,se_detail_emit emit,void *ctx){
 if(!s || !rgb || !emit || n<0 || s->ended || n>s->h-s->seen)return SE_E_CORRUPT;
 for(int i=0;i<n;i++){
  const uint8_t *row=rgb+(size_t)i*s->w*3;se_err rc;
  if(!s->seen)for(int k=0;k<s->r;k++){rc=push(s,row,emit,ctx);if(rc)return rc;}
  rc=push(s,row,emit,ctx);if(rc)return rc;s->seen++;
 }
 return SE_OK;
}
se_err se_detail_end(se_detail_run *s,se_detail_emit emit,void *ctx){
 if(!s || !emit || s->ended || s->seen!=s->h)return SE_E_CORRUPT;
 s->ended=1;
 for(int k=0;k<s->r;k++){const uint8_t *last=s->rgb+(size_t)((s->pushed-1)%s->ndelay)*s->w*3;se_err rc=push(s,last,emit,ctx);if(rc)return rc;}
 return SE_OK;
}
void se_detail_shade(uint8_t *row,int w,int h,int y,int amount){
 if(!amount || !row || w<1 || h<1)return;
 int dy=h>1?(y*512+(h-1)/2)/(h-1)-256:0;
 int denominator=w>1?w-1:1,step=512/denominator,remainder=512%denominator,position=0,error=denominator/2;
 for(int x=0;x<w;x++){
  int dx=w>1?position-256:0;
  position+=step;error+=remainder;if(error>=denominator){position++;error-=denominator;}
  int radial=(dx*dx+dy*dy)/2,gain=256+amount*radial/2048;
  for(int c=0;c<3;c++)row[3*x+c]=clip((row[3*x+c]*gain+128)/256);
 }
}
