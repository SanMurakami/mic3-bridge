#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#include "../driver/Driver.c"
static void putPacket(AudioObjectID deviceID,DJIPacket *p,UInt32 length,OSStatus expected) {
    CFDataRef data=CFDataCreate(NULL,(const UInt8*)p,length);
    AudioObjectPropertyAddress a={DJI_PACKET_SELECTOR,kAudioObjectPropertyScopeGlobal,0};
    assert(Set(DriverRef,deviceID,getpid(),&a,0,NULL,sizeof(data),&data)==expected);CFRelease(data);
}
int main(void) {
    assert(DJIMicFactory(NULL,kAudioServerPlugInTypeUUID)==DriverRef);
    assert(Initialize(DriverRef,NULL)==noErr);
    UInt32 size=0,used=0;AudioObjectPropertyAddress a={kAudioPlugInPropertyDeviceList,kAudioObjectPropertyScopeGlobal,0};
    assert(PropertySize(DriverRef,Plugin,0,&a,0,NULL,&size)==noErr&&size==0);
    CFMutableArrayRef rows=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    for(int i=0;i<12;i++) {
        CFStringRef u=CFStringCreateWithFormat(NULL,NULL,CFSTR("local.dji-mic.input.test-%d"),i);
        const void *keys[]={CFSTR("uid"),CFSTR("name")},*values[]={u,CFSTR("テスト入力")};
        CFDictionaryRef row=CFDictionaryCreate(NULL,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(rows,row);CFRelease(row);CFRelease(u);
    }
    a.mSelector=DJI_DEVICES_SELECTOR;
    assert(Set(DriverRef,Plugin,0,&a,0,NULL,sizeof(rows),&rows)==noErr);
    // 再登録で重複しない。2 台を超えて動的に追加でき、空の登録でも切断中の入力を残す。
    assert(Set(DriverRef,Plugin,0,&a,0,NULL,sizeof(rows),&rows)==noErr);
    CFRelease(rows);rows=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    assert(Set(DriverRef,Plugin,0,&a,0,NULL,sizeof(rows),&rows)==noErr);CFRelease(rows);
    CFStringRef invalid=CFSTR("不正");
    assert(Set(DriverRef,Plugin,0,&a,0,NULL,sizeof(invalid),&invalid)==kAudioHardwareIllegalOperationError);
    a.mSelector=kAudioPlugInPropertyDeviceList;
    assert(PropertySize(DriverRef,Plugin,0,&a,0,NULL,&size)==noErr&&size==12*sizeof(AudioObjectID));
    AudioObjectID devices[12]={0};assert(Get(DriverRef,Plugin,0,&a,0,NULL,sizeof(devices),&used,devices)==noErr);
    AudioObjectID DeviceA=devices[0],DeviceB=devices[1],StreamA=DeviceA+1,StreamB=DeviceB+1;
    a=(AudioObjectPropertyAddress){kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput,0};
    assert(PropertySize(DriverRef,DeviceA,0,&a,0,NULL,&size)==noErr&&size==0);
    a=(AudioObjectPropertyAddress){kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,0};
    for(int i=0;i<2;i++){CFStringRef value=NULL;assert(Get(DriverRef,devices[i],0,&a,0,NULL,sizeof(value),&used,&value)==noErr);assert(CFEqual(value,uid(slot(devices[i]))));CFRelease(value);}
    a=(AudioObjectPropertyAddress){kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,0};
    double unsupported=44100;assert(Set(DriverRef,DeviceA,0,&a,0,NULL,sizeof(unsupported),&unsupported)==kAudioDeviceUnsupportedFormatError);
    DJIPacket packet={.version=1,.frames=1024,.channels=4,.sourceRate=48000,.rateScalar=1};
    packet.hostTime=mach_absolute_time()-(uint64_t)(HostFrequency*.1);
    for(unsigned f=0;f<packet.frames;f++)for(unsigned ch=0;ch<4;ch++)packet.samples[f*4+ch]=.125f*(ch+1);
    UInt32 bytes=offsetof(DJIPacket,samples)+packet.frames*16;
    putPacket(DeviceA,&packet,bytes,noErr);
    for(unsigned i=0;i<packet.frames*4;i++)packet.samples[i]*=-1;
    putPacket(DeviceB,&packet,bytes,noErr);
    uint64_t frame=(uint64_t)ceil((double)packet.hostTime*48000/HostFrequency)+100;
    AudioServerPlugInIOCycleInfo info={0};info.mInputTime.mFlags=kAudioTimeStampHostTimeValid;
    info.mInputTime.mHostTime=(uint64_t)llround((frame+DJI_DELAY_FRAMES)*HostFrequency/48000);
    float first[64*4],second[64*4],repeat[64*4];
    assert(IO(DriverRef,DeviceA,StreamA,1,kAudioServerPlugInIOOperationReadInput,64,&info,first,NULL)==noErr);
    assert(IO(DriverRef,DeviceB,StreamB,1,kAudioServerPlugInIOOperationReadInput,64,&info,second,NULL)==noErr);
    assert(IO(DriverRef,DeviceA,StreamA,2,kAudioServerPlugInIOOperationReadInput,64,&info,repeat,NULL)==noErr);
    for(unsigned i=0;i<64*4;i++){assert(first[i]==.125f*(i%4+1));assert(second[i]==-first[i]);assert(repeat[i]==first[i]);}
    putPacket(DeviceA,&packet,bytes-4,kAudioHardwareBadPropertySizeError);
    packet.frames=UINT32_MAX;putPacket(DeviceA,&packet,bytes,kAudioHardwareBadPropertySizeError);packet.frames=1024;
    packet.sourceRate=NAN;putPacket(DeviceA,&packet,bytes,kAudioHardwareBadPropertySizeError);packet.sourceRate=48000;
    for(UInt32 length=0;length<offsetof(DJIPacket,samples);length++)putPacket(DeviceA,&packet,length,kAudioHardwareBadPropertySizeError);
    UInt32 value=1;CFDataRef resetData=CFDataCreate(NULL,(const UInt8*)&value,sizeof(value));
    a=(AudioObjectPropertyAddress){DJI_RESET_SELECTOR,kAudioObjectPropertyScopeGlobal,0};
    assert(Set(DriverRef,DeviceA,0,&a,0,NULL,sizeof(resetData),&resetData)==noErr);CFRelease(resetData);
    assert(IO(DriverRef,DeviceA,StreamA,1,kAudioServerPlugInIOOperationReadInput,64,&info,first,NULL)==noErr);
    for(unsigned i=0;i<64*4;i++)assert(first[i]==0);
    // リング一周後の古いサンプルを新しい時刻の音として読まない。
    DJIRead(slot(DeviceB)->ring,frame+DJI_RING_FRAMES,64,second);for(unsigned i=0;i<64*4;i++)assert(second[i]==0);
    // 44.1kHz のタイムスタンプを仮想 48kHz の timeline へ変換する。
    packet.sourceRate=44100;for(unsigned i=0;i<packet.frames*4;i++)packet.samples[i]=.25f;
    putPacket(DeviceA,&packet,bytes,noErr);DJIRead(slot(DeviceA)->ring,frame,64,first);for(unsigned i=0;i<64*4;i++)assert(first[i]==.25f);
    assert(Start(DriverRef,DeviceA,1)==noErr);double sample;uint64_t host,seed;
    assert(Zero(DriverRef,DeviceA,1,&sample,&host,&seed)==noErr);uint64_t previousSeed=seed;
    assert(Stop(DriverRef,DeviceA,1)==noErr);assert(Start(DriverRef,DeviceA,1)==noErr);
    assert(Zero(DriverRef,DeviceA,1,&sample,&host,&seed)==noErr&&seed>previousSeed);
    puts("driver: 独立した入力・複数読者・無音・不正 packet・リセット・レート変換・clock 再開 OK");
}
