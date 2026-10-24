#import <Foundation/Foundation.h>
#include <cassert>
#include <cmath>
#include "../bridge/Recorder.hpp"
int main(){@autoreleasepool{
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *path=[dir stringByAppendingPathComponent:@"four.caf"];
    float samples[1024*4];for(unsigned f=0;f<1024;f++)for(unsigned c=0;c<4;c++)samples[f*4+c]=(float)(c+1)/8;
    {dji::Recorder recorder(path.fileSystemRepresentation,48000);for(int i=0;i<8;i++)recorder.append(samples,1024);assert(recorder.frames==8192);assert(recorder.close()==noErr);}
    bool rejected=false;try{dji::Recorder duplicate(path.fileSystemRepresentation,48000);}catch(...){rejected=true;}assert(rejected);
    AudioFileID file=nullptr;assert(AudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],kAudioFileReadPermission,0,&file)==noErr);
    AudioStreamBasicDescription format{};UInt32 size=sizeof(format);assert(AudioFileGetProperty(file,kAudioFilePropertyDataFormat,&size,&format)==noErr);
    assert(format.mSampleRate==48000&&format.mChannelsPerFrame==4&&format.mBitsPerChannel==32);
    UInt64 bytes=0;size=sizeof(bytes);assert(AudioFileGetProperty(file,kAudioFilePropertyAudioDataByteCount,&size,&bytes)==noErr&&bytes==8192*16);
    float read[1024*4];size=sizeof(read);assert(AudioFileReadBytes(file,false,0,&size,read)==noErr);
    for(unsigned i=0;i<1024*4;i++)assert(read[i]==samples[i]);assert(AudioFileClose(file)==noErr);
    assert([[NSFileManager defaultManager] removeItemAtPath:dir error:nil]);
    puts("recorder: 4ch Float32 の一致・長さ・終了処理・上書き拒否 OK");
}}
