/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "preview.h"
static uint32_t u16(const uint8_t *p){return (uint32_t)p[0]|((uint32_t)p[1]<<8);}
static uint32_t u32(const uint8_t *p){return u16(p)|(u16(p+2)<<16);}
int cap_preview_locate(const uint8_t *h,size_t n,uint32_t total,cap_preview *out){
 if(!h || !out || n<16 || n>8192 || total<n || h[0]!='I' || h[1]!='I' || u16(h+2)!=42 || h[8]!='C' || h[9]!='R' || h[10]!=2 || h[11]!=0)return 0;
 uint32_t dir=u32(h+4);if(dir<16 || dir>n-2)return 0;
 uint32_t count=u16(h+dir);if(!count || count>64 || n-dir<6 || count>(n-dir-6)/12)return 0;
 cap_preview value={0};uint32_t seen=0,dir_end=dir+6+count*12;
 for(uint32_t i=0;i<count;i++){
  uint32_t at=dir+2+i*12,tag=u16(h+at),type=u16(h+at+2),bit=0;
  if(tag==0x100)bit=1;else if(tag==0x101)bit=2;else if(tag==0x103)bit=4;else if(tag==0x111)bit=8;else if(tag==0x117)bit=16;else if(tag==0x112)bit=32;else continue;
  if((seen&bit) || u32(h+at+4)!=1 || (type!=3 && type!=4))return 0;
  seen|=bit;uint32_t v=type==3?u16(h+at+8):u32(h+at+8);
  if(bit==1)value.width=v;else if(bit==2)value.height=v;else if(bit==4){if(v!=6)return 0;}
  else if(bit==8){if(type!=4)return 0;value.offset=v;}
  else if(bit==16){if(type!=4)return 0;value.bytes=v;}
  else{if(type!=3 || v<1 || v>8)return 0;value.orientation=v;value.orientation_offset=at+8;}
 }
 if(seen!=63 || value.width!=2256 || value.height!=1504 || value.offset<dir_end || !value.bytes || value.bytes>CAP_PREVIEW_MAX || value.offset>total || value.bytes>total-value.offset || value.orientation_offset>value.offset-2)return 0;
 *out=value;return 1;
}
