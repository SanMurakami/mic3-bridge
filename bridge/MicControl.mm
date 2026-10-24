// Mic 3のNC level 0x0037とenable 0x0038を制御する。
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include <chrono>
#include <map>
#include <set>
#include "../bridge/MicIdentity.hpp"
static NSString *hex(const uint8_t *p,size_t n){NSMutableString *s=[NSMutableString string];for(size_t i=0;i<n;i++)[s appendFormat:@"%02x",p[i]];return s;}
int main(int argc,const char *argv[]){@autoreleasepool{
 bool apply=argc==5&&std::string(argv[1])=="--set";
 if((!apply&&argc!=2)||!dji::validSerial(argv[apply?2:1]))return 1;
 unsigned requestedTarget=apply?(unsigned)std::stoul(argv[3]):0;std::string mode=apply?argv[4]:"";
 if(apply&&(requestedTarget<1||requestedTarget>4||(mode!="none"&&mode!="basic"&&mode!="strong")))return 1;
 std::string expected=argv[apply?2:1];NSMutableArray *results=[NSMutableArray array];io_iterator_t it=0;
 IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostInterface"),&it);io_service_t service;
 while((service=IOIteratorNext(it))){
  CFMutableDictionaryRef cf=nullptr;IORegistryEntryCreateCFProperties(service,&cf,kCFAllocatorDefault,0);NSDictionary *p=CFBridgingRelease(cf);
  if([p[@"idVendor"] unsignedIntValue]!=0x2ca3||[p[@"bInterfaceNumber"] unsignedIntValue]!=4||[p[@"bInterfaceClass"] unsignedIntValue]!=255){IOObjectRelease(service);continue;}
  NSError *error=nil;IOUSBHostInterface *iface=[[IOUSBHostInterface alloc] initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];IOObjectRelease(service);if(!iface)continue;
  unsigned previous=iface.interfaceDescriptor?iface.interfaceDescriptor->bAlternateSetting:0;
  if(previous!=1&&![iface selectAlternateSetting:1 error:&error]){[iface destroy];continue;}
  IOUSBHostPipe *in=[iface copyPipeWithAddress:0x81 error:&error],*out=[iface copyPipeWithAddress:1 error:&error];
  dji::IdentityParser parser;std::map<uint32_t,uint32_t> tx;std::set<uint16_t> acknowledged;NSMutableArray *events=[NSMutableArray array];
  parser.onFrame=[&](const uint8_t *f,size_t n){
   if(f[8]&128){[events addObject:@{@"response":hex(f,n)}];if(n==14&&f[9]==0x5b&&f[10]==1&&f[11]==0)acknowledged.insert((uint16_t)(f[6]|f[7]<<8));return;}
   if(n<16||f[9]!=0x5b||f[10]!=3||f[11]!=3)return;
   auto data=f+11;size_t size=n-13;if(size!=(size_t)(data[1]|data[2]<<8)+3)return;
   for(size_t at=3;at+6<=size;){unsigned type=data[at],length=data[at+5];uint32_t index=data[at+1]|data[at+2]<<8|data[at+3]<<16|(uint32_t)data[at+4]<<24;
    if(length>size-at-6)return;
    if(type==2&&length>=4&&index>=1&&index<=4){auto v=data+at+6;uint32_t word=v[0]|v[1]<<8|v[2]<<16|(uint32_t)v[3]<<24;
     if(!tx.count(index)||tx[index]!=word){[events addObject:@{@"tx":@(index),@"nc_enabled":@((word>>8)&1),@"nc_level":@((word>>5)&3),@"word":@(word)}];}tx[index]=word;}
    at+=6+length;
   }
  };
  auto readFor=[&](double seconds){auto start=std::chrono::steady_clock::now();while(in&&std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()<seconds){NSMutableData *data=[NSMutableData dataWithLength:2048];NSUInteger got=0;NSError *e=nil;[in sendIORequestWithData:data bytesTransferred:&got completionTimeout:.15 error:&e];if(got)parser.append((const uint8_t*)data.bytes,got);}};
  readFor(1.5);
  if(parser.identity.serial==expected&&!tx.empty()&&out&&(!apply||tx.count(requestedTarget))){
   auto first=apply?*tx.find(requestedTarget):*tx.begin();uint32_t target=first.first;unsigned enabled=(first.second>>8)&1,level=(first.second>>5)&3;uint16_t sequence=0x6e00,lastSequence=0;
   auto send=[&](unsigned setting,unsigned value){lastSequence=sequence;std::vector<uint8_t> f(22,0);f[0]=0x55;f[1]=22;f[2]=4;f[3]=dji::crc8(f.data(),3);f[4]=2;f[5]=0x5a;f[6]=sequence&255;f[7]=sequence++>>8;f[8]=0x40;f[9]=0x5b;f[10]=1;f[11]=2;f[12]=target&255;f[13]=target>>8;f[16]=setting&255;f[17]=setting>>8;f[18]=1;f[19]=value;auto crc=dji::crc16(f.data(),20);f[20]=crc&255;f[21]=crc>>8;
    NSMutableData *data=[NSMutableData dataWithBytes:f.data() length:f.size()];NSUInteger count=0;NSError *e=nil;BOOL ok=[out sendIORequestWithData:data bytesTransferred:&count completionTimeout:.5 error:&e];[events addObject:@{@"request":hex(f.data(),f.size()),@"sent":@(count),@"ok":@(ok),@"error":e.description?:@""}];};
   // NC強度の範囲を検証し、終了時に初期値を復元する。
   bool success=false;
   if(level<=1){
    if(apply){
     auto commit=[&](unsigned setting,unsigned value){for(int attempt=0;attempt<2;attempt++){send(setting,value);readFor(.7);if(acknowledged.count(lastSequence))return true;}return false;};
     bool accepted=true;if(mode!="none")accepted=commit(0x37,mode=="strong"?1:0);
     accepted=commit(0x38,mode=="none"?0:1)&&accepted;readFor(.3);
     success=accepted&&tx.count(target)&&((tx[target]>>8)&1)==(mode!="none")&&(mode=="none"||((tx[target]>>5)&3)==(mode=="strong"?1:0));
     if(!success){commit(0x37,level);commit(0x38,enabled);readFor(.3);}
    }else{send(0x38,enabled);readFor(.5);send(0x38,!enabled);readFor(1);send(0x38,enabled);readFor(1);send(0x37,!level);readFor(1);send(0x37,level);readFor(1.5);}
   }
   bool restored=tx.count(target)&&((tx[target]>>8)&1)==enabled&&((tx[target]>>5)&3)==level;
   [results addObject:@{@"success":@(success),@"serial":@(expected.c_str()),@"target":@(target),@"initial_enabled":@(enabled),@"initial_level":@(level),@"restored":@(restored),@"events":events}];
  }
  if(previous!=1)[iface selectAlternateSetting:previous error:nil];[iface destroy];
 }
 IOObjectRelease(it);NSData *data=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);putchar('\n');
 return results.count&&(!apply||[results[0][@"success"] boolValue])?0:2;
}}
