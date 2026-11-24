/* SPDX-License-Identifier: GPL-2.0-only */
#include "metadata.h"
static uint32_t le16(const volatile uint8_t *p){return p[0]|((uint32_t)p[1]<<8);}
static uint32_t le32(const volatile uint8_t *p){return le16(p)|(le16(p+2)<<16);}
int wf_output_orientation(volatile uint8_t *p,uint32_t n,uint32_t orientation){
 if(!p || n<24 || (orientation!=1 && orientation!=3 && orientation!=6 && orientation!=8))return -1;
 if(p[0]!=255 || p[1]!=216 || p[2]!=255 || p[3]!=224)return -1;
 uint32_t app0=((uint32_t)p[4]<<8)|p[5];
 if(app0<7 || app0>n-4 || p[6]!='J' || p[7]!='F' || p[8]!='I' || p[9]!='F' || p[10])return -1;
 uint32_t app1=4+app0;
 if(n-app1<22 || p[app1]!=255 || p[app1+1]!=225)return -1;
 uint32_t length=((uint32_t)p[app1+2]<<8)|p[app1+3];
 if(length<18 || length>n-app1-2)return -1;
 static const uint8_t prefix[10]={'E','x','i','f',0,0,'I','I',42,0};
 for(unsigned i=0;i<10;i++)if(p[app1+4+i]!=prefix[i])return -1;
 uint32_t tiff=app1+10,end=app1+2+length,offset=le32(p+tiff+4);
 if(offset<8 || offset>end-tiff-2)return -1;
 uint32_t start=tiff+offset,count=le16(p+start);
 if(count>16 || 2+12*count+4>end-start)return -1;
 uint32_t value=0;
 for(unsigned i=0;i<count;i++){
  uint32_t at=start+2+12*i;
  if(le16(p+at)!=0x112)continue;
  if(value || le16(p+at+2)!=3 || le32(p+at+4)!=1 || le32(p+at+8)!=1)return -1;
  value=at+8;
 }
 if(!value)return -1;
 p[value]=(uint8_t)orientation;p[value+1]=0;return 0;
}
