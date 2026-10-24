#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <string>
#include <stdexcept>
namespace dji {
// CAF は 64-bit の長さを扱える。音声 callback 外でだけ使用する。
class Recorder {
    AudioFileID file=nullptr;
    SInt64 offset=0;
public:
    uint64_t frames=0;
    std::string path;
    Recorder(const std::string& path,double rate):path(path) {
        AudioStreamBasicDescription format{};format.mSampleRate=rate;format.mFormatID=kAudioFormatLinearPCM;
        format.mFormatFlags=kAudioFormatFlagsNativeFloatPacked;format.mBytesPerPacket=16;format.mFramesPerPacket=1;
        format.mBytesPerFrame=16;format.mChannelsPerFrame=4;format.mBitsPerChannel=32;
        CFURLRef url=CFURLCreateFromFileSystemRepresentation(nullptr,(const UInt8*)path.data(),path.size(),false);
        // 既存ファイルがある場合は作成を失敗させる。
        auto status=AudioFileCreateWithURL(url,kAudioFileCAFType,&format,0,&file);CFRelease(url);
        if(status)throw std::runtime_error("録音ファイル作成エラー: "+std::to_string(status));
    }
    void append(const float *samples,uint32_t count) {
        UInt32 bytes=count*16,requested=bytes;auto status=AudioFileWriteBytes(file,false,offset,&bytes,samples);
        if(status||bytes!=requested)throw std::runtime_error("録音書き込みエラー: "+std::to_string(status));
        offset+=bytes;frames+=count;
    }
    OSStatus close(){if(!file)return noErr;auto f=file;file=nullptr;return AudioFileClose(f);}
    ~Recorder(){close();}
};
}
