/* SPDX-License-Identifier: GPL-2.0-or-later
 * Bounded installer body; placement and packaging are separate reviewed tools.
 */
#include <stdint.h>
#include "signatures.h"
#define WORD(a) (*(volatile uint32_t *)(uintptr_t)(a))
#ifndef DISABLE
#define DISABLE 0
#endif
enum { OK=0, ALREADY=1, CODE=2, GEOMETRY=3, CACHE=4, VALUE=5,
       ALLOC=6, ALLOC_RANGE=7, PRECALL=8, POSTCALL=9, NATIVE=10,
       FLAG=11, COLLATERAL=12 };
static int heap(uint32_t p,uint32_t n){
 return !(p&3) && p>=0x180000 && n<=0x700000-p && p<=0x700000;
}
static int code_ok(void){
 for(uint32_t i=0;i<sizeof fingerprints/sizeof fingerprints[0];i++){
  uint32_t h=2166136261u;
  for(uint32_t a=fingerprints[i][0];a<fingerprints[i][1];a++)
   h=(h^*(volatile uint8_t *)(uintptr_t)a)*16777619u;
  if(h!=fingerprints[i][2])return 0;
 }
 for(uint32_t i=0;i<sizeof signatures/sizeof signatures[0];i++)
  if(WORD(signatures[i][0])!=signatures[i][1])return 0;
 for(uint32_t i=0;i<17;i++)if(WORD(0x1d9c+8*i)!=0x8092a8)return 0;
 return 1;
}
static int geometry_ok(void){
 uint32_t s=WORD(0x31c8),link,node,table;
 if(WORD(0x31c4)!=1 || !heap(s,8))return 0;
 link=WORD(s);
 if(link!=WORD(s+4) || link<0x24)return 0;
 node=link-0x24;
 if(!heap(node,0x2c) || WORD(node+0x24)!=s || WORD(node+0x28)!=s)return 0;
 static const uint32_t fixed[]={1,142,0xf8000000,0x800000,0x973da0,0x9741e4,0x974268,0x9742cc};
 if(WORD(node)!=fixed[0])return 0;
 for(uint32_t i=1;i<8;i++)if(WORD(node+4+4*i)!=fixed[i])return 0;
 table=WORD(node+4);if(!heap(table,0x478))return 0;
 uint32_t offset=0;
 for(uint32_t i=0;i<142;i++){
  uint32_t size=(i<8 || i>=134)?8192:65536;
  if(WORD(table+8*i)!=offset || WORD(table+8*i+4)!=size)return 0;
  offset+=size;
 }
 if(offset!=0x800000 || WORD(table+1136)!=0xffff || WORD(table+1140))return 0;
 uint32_t base=0,out=0;
 if(((uint32_t (*)(uint32_t))0x96cd40)(0xf8000004)!=1)return 0;
 if(((uint32_t (*)(uint32_t,uint32_t *,uint32_t *))0x96cc04)(1,&base,&out))return 0;
 return base==0xf8000000 && out==table;
}
static int cache_ok(void){
 uint32_t ctr,control;
 __asm__ volatile("mrc p15,0,%0,c0,c0,1":"=r"(ctr));
 __asm__ volatile("mrc p15,0,%0,c1,c0,0":"=r"(control));
 static const uint32_t bindings[][2]={
  {0x3a70,0x99cec0},{0x3a74,0x99ce48},{0x3a80,0x99cdd4},
  {0x3328,0x977b74},{0x332c,0x977b88},{0x3f40,1},
  {0x3f54,0x7e0},{0x3f30,0xc0},{0x3d34,0},{0x3f34,0x100c}};
 if(ctr!=0x0f112112 || (control&0x1005)!=0x1005)return 0;
 for(uint32_t i=0;i<sizeof bindings/sizeof bindings[0];i++)
  if(WORD(bindings[i][0])!=bindings[i][1])return 0;
 return 1;
}
/* result: raw status, comparison bits (flag1/collateral2), pointer, freed. */
uint32_t installer_body(uint32_t result[4]){
 const uint32_t desired=DISABLE?0:0xffffffffu,expected=~desired;
 uint32_t status=OK;
 result[0]=result[1]=0xffffffffu;result[2]=result[3]=0;
 if(!code_ok())return CODE;
 if(!geometry_ok())return GEOMETRY;
 if(!cache_ok())return CACHE;
 ((void (*)(void))0x96d774)();
 ((void (*)(void))0x96d75c)();
 if(!cache_ok() || !geometry_ok() || WORD(0xf8000008)!=0xffffffffu)return CACHE;
 uint32_t initial=WORD(0xf8000004);
 if(initial==desired)return ALREADY;
 if(initial!=expected)return VALUE;
 uint32_t backup=((uint32_t (*)(uint32_t))0x96d7bc)(8192);
 result[2]=backup;
 if(!backup)return ALLOC;
 if(!(backup&0x10000000) || !heap(backup&~0x10000000u,8192)){
  return ALLOC_RANGE; /* Untrusted pointer is not dereferenced or freed. */
 }
 ((void *(*)(uint32_t,uint32_t,uint32_t))0x991a2c)(backup,0xf8000000,8192);
 if(!code_ok() || !geometry_ok() || !cache_ok())return PRECALL;
 if(WORD(backup+4)!=expected || WORD(0xf8000004)!=expected){status=PRECALL;goto finish;}
 result[0]=((uint32_t (*)(void))(DISABLE?0x972a14:0x9729fc))();
 if(!code_ok() || !geometry_ok() || !cache_ok())return POSTCALL;
 result[1]=WORD(0xf8000004)!=desired?1:0;
 for(uint32_t i=0;i<2048;i++){
  if(i!=1 && WORD(0xf8000000+4*i)!=WORD(backup+4*i))result[1]|=2;
 }
 status=result[0]?NATIVE:(result[1]&2)?COLLATERAL:(result[1]&1)?FLAG:OK;
finish:
 ((void (*)(uint32_t))0x96d7e8)(backup);
 result[3]=1;
 return status;
}
