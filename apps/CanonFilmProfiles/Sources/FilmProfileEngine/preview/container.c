/* SPDX-License-Identifier: GPL-2.0-only */
#include "container.h"
int wf_output_exif_first(volatile uint8_t *p,uint32_t n){
 static const uint8_t prefix[20]={255,216,255,224,0,16,'J','F','I','F',0,1,1,0,0,1,0,1,0,0};
 static const uint8_t exif[10]={'E','x','i','f',0,0,'I','I',42,0};
 if(!p || n<38)return -1;
 for(unsigned i=0;i<20;i++)if(p[i]!=prefix[i])return -1;
 if(p[20]!=255 || p[21]!=225)return -1;
 uint32_t length=((uint32_t)p[22]<<8)|p[23];
 if(length<16 || length>n-22)return -1;
 for(unsigned i=0;i<10;i++)if(p[24+i]!=exif[i])return -1;
 uint8_t app0[18];for(unsigned i=0;i<18;i++)app0[i]=p[2+i];
 uint32_t segment=length+2;
 for(uint32_t i=0;i<segment;i++)p[2+i]=p[20+i];
 for(unsigned i=0;i<18;i++)p[2+segment+i]=app0[i];
 return 0;
}
