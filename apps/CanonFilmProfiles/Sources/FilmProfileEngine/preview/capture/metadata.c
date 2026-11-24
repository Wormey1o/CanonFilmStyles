/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "metadata.h"
static uint32_t le16(const uint8_t *p){return (uint32_t)p[0]|((uint32_t)p[1]<<8);}
static uint32_t le32(const uint8_t *p){return le16(p)|(le16(p+2)<<16);}
static uint32_t be16(const uint8_t *p){return ((uint32_t)p[0]<<8)|p[1];}
static int orientation(uint32_t n){return n==1 || n==3 || n==6 || n==8;}
int cap_cr2_admit(const uint8_t *h,size_t n,uint32_t total,cap_metadata *out){
 if(!out)return 0;
 cap_metadata m={0};if(!cap_preview_locate(h,n,total,&m.preview) || !orientation(m.preview.orientation))return 0;
 uint32_t dir=le32(h+4),count=le16(h+dir),end=dir+6+count*12,seen=0;
 for(uint32_t i=0;i<count;i++){
  uint32_t at=dir+2+i*12;if(le16(h+at)!=0x8769)continue;
  if(seen || le16(h+at+2)!=4 || le32(h+at+4)!=1)return 0;
  seen=1;m.exif_ifd=le32(h+at+8);
 }
 if(!seen || m.exif_ifd<end || m.exif_ifd>n-2 || n-m.exif_ifd<6)return 0;
 count=le16(h+m.exif_ifd);if(!count || count>128 || count>(n-m.exif_ifd-6)/12 || m.exif_ifd+6+count*12>m.preview.offset)return 0;
 seen=0;
 for(uint32_t i=0;i<count;i++){
  uint32_t at=m.exif_ifd+2+i*12;if(le16(h+at)!=0xa001)continue;
  if(seen || le16(h+at+2)!=3 || le32(h+at+4)!=1 || le16(h+at+8)!=1)return 0;
  seen=1;m.color_space=1;m.color_value_offset=at+8;
 }
 if(!seen)return 0;
 *out=m;return 1;
}
int cap_preview_jpeg_admit(const uint8_t *h,size_t n,const cap_metadata *m){
 if(!h || !m || n<4 || n>8192 || m->color_space!=1 || !orientation(m->preview.orientation) || m->preview.width!=2256 || m->preview.height!=1504 || h[0]!=255 || h[1]!=216)return 0;
 size_t pos=2;uint32_t frame=0,quant=0,dc=0,ac=0,needed_quant=0,restart=0;
 while(pos<n){
  if(h[pos++]!=255)return 0;
  while(pos<n && h[pos]==255)pos++;
  if(pos==n)return 0;
  uint32_t marker=h[pos++];if(marker==0 || marker==1 || (marker>=0xd0 && marker<=0xd9) || n-pos<2)return 0;
  uint32_t length=be16(h+pos);if(length<2 || length>n-pos)return 0;const uint8_t *p=h+pos+2;uint32_t bytes=length-2;
  if(marker==0xc0){
   if(frame || bytes!=15 || p[0]!=8 || be16(p+1)!=1504 || be16(p+3)!=2256 || p[5]!=3)return 0;
   for(unsigned i=0;i<3;i++){
    if(p[6+i*3]!=i+1 || p[8+i*3]>3)return 0;
    uint32_t sample=p[7+i*3];if((i && sample!=0x11) || (!i && sample!=0x11 && sample!=0x21 && sample!=0x22))return 0;
    needed_quant|=1u<<p[8+i*3];
   }
   frame=1;
  }else if(marker==0xdb){
   if(!bytes)return 0;
   uint32_t at=0;while(at<bytes){uint32_t id=p[at++];if(id>3 || (quant&(1u<<id)) || bytes-at<64)return 0;for(unsigned i=0;i<64;i++)if(!p[at+i])return 0;quant|=1u<<id;at+=64;}
  }else if(marker==0xc4){
   if(!bytes)return 0;
   uint32_t at=0;while(at<bytes){
    uint32_t id=p[at++],table=id&15,kind=id>>4;if(kind>1 || table>3 || bytes-at<16)return 0;
    uint32_t *mask=kind?&ac:&dc;if(*mask&(1u<<table))return 0;uint32_t symbols=0,available=1;
    for(unsigned i=0;i<16;i++){uint32_t count=p[at+i];available*=2;if(count>available)return 0;available-=count;symbols+=count;}
    at+=16;if(!available || !symbols || symbols>256 || symbols>bytes-at)return 0;
    for(uint32_t i=0;i<symbols;i++){uint32_t v=p[at+i];if(!kind){if(v>11)return 0;}else if(!(v&15)){if(v!=0 && v!=0xf0)return 0;}else if((v&15)>10)return 0;}
    at+=symbols;*mask|=1u<<table;
   }
  }else if(marker==0xdd){if(restart || bytes!=2)return 0;restart=1;
  }else if(marker==0xe0){if(bytes<14 || p[0]!='J' || p[1]!='F' || p[2]!='I' || p[3]!='F' || p[4])return 0;
  }else if(marker==0xfe){/* Comment has no color-space authority. */
  }else if(marker==0xda){
   if(!frame || bytes!=10 || p[0]!=3 || (quant&needed_quant)!=needed_quant || p[7]!=0 || p[8]!=63 || p[9]!=0)return 0;
   for(unsigned i=0;i<3;i++){uint32_t selector=p[2+i*2];if(p[1+i*2]!=i+1 || (selector>>4)>3 || (selector&15)>3 || !(dc&(1u<<(selector>>4))) || !(ac&(1u<<(selector&15))))return 0;}
   return pos+length<n;
  }else return 0;
  pos+=length;
 }
 return 0;
}
