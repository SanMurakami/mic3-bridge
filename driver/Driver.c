/* AudioServerPlugIn のインターフェイス構成は Apple NullAudio サンプルを参考にした。
 * Apple のライセンスは ../vendor/apple-null-audio/LICENSE.txt に保持する。 */
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include "Timeline.h"

enum { Plugin=1, DeviceA=2, StreamA=3, DeviceB=4, StreamB=5 };
static AudioServerPlugInDriverInterface Interface;
static AudioServerPlugInDriverInterface *InterfacePtr=&Interface;
static AudioServerPlugInDriverRef DriverRef=&InterfacePtr;
static _Atomic unsigned RefCount=1;
static DJITimeline Rings[2];
static DJIStatus Stats[2];
static pthread_mutex_t StateLock=PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t WriteLocks[2]={PTHREAD_MUTEX_INITIALIZER,PTHREAD_MUTEX_INITIALIZER};
static uint64_t Running[2],Anchors[2],Seeds[2]={1,1};
static double HostFrequency;
static int slot(AudioObjectID id) { return id==DeviceA||id==StreamA?0:id==DeviceB||id==StreamB?1:-1; }
static int device(AudioObjectID id) { return id==DeviceA||id==DeviceB; }
static int stream(AudioObjectID id) { return id==StreamA||id==StreamB; }
static CFStringRef name(int n) { return n?CFSTR("DJI Mic3 RX B"):CFSTR("DJI Mic3 RX A"); }
static CFStringRef uid(int n) { return n?CFSTR(DJI_UID_B):CFSTR(DJI_UID_A); }
static AudioStreamBasicDescription format(void) {
    return (AudioStreamBasicDescription){.mSampleRate=DJI_SAMPLE_RATE,.mFormatID=kAudioFormatLinearPCM,
        .mFormatFlags=kAudioFormatFlagsNativeFloatPacked,.mBytesPerPacket=16,.mFramesPerPacket=1,
        .mBytesPerFrame=16,.mChannelsPerFrame=4,.mBitsPerChannel=32};
}
static HRESULT Query(void *driver,REFIID iid,LPVOID *out) {
    if(driver!=DriverRef||!out)return E_INVALIDARG;
    CFUUIDRef uuid=CFUUIDCreateFromUUIDBytes(NULL,iid);
    bool ok=CFEqual(uuid,IUnknownUUID)||CFEqual(uuid,kAudioServerPlugInDriverInterfaceUUID);CFRelease(uuid);
    *out=ok?DriverRef:NULL;if(ok)atomic_fetch_add(&RefCount,1);return ok?S_OK:E_NOINTERFACE;
}
static ULONG AddRef(void *d) { return d==DriverRef?atomic_fetch_add(&RefCount,1)+1:0; }
static ULONG Release(void *d) { return d==DriverRef?atomic_fetch_sub(&RefCount,1)-1:0; }
static OSStatus Initialize(AudioServerPlugInDriverRef d,AudioServerPlugInHostRef host) {
    (void)host;if(d!=DriverRef)return kAudioHardwareBadObjectError;
    mach_timebase_info_data_t timebase;mach_timebase_info(&timebase);
    HostFrequency=1e9*(double)timebase.denom/timebase.numer;
    return noErr;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d,CFDictionaryRef desc,const AudioServerPlugInClientInfo *c,AudioObjectID *id) {
    (void)d;(void)desc;(void)c;(void)id;return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d,AudioObjectID id) { (void)d;(void)id;return kAudioHardwareUnsupportedOperationError; }
static OSStatus Client(AudioServerPlugInDriverRef d,AudioObjectID id,const AudioServerPlugInClientInfo *c) {
    (void)c;return d==DriverRef&&device(id)?noErr:kAudioHardwareBadObjectError;
}
static OSStatus Config(AudioServerPlugInDriverRef d,AudioObjectID id,UInt64 action,void *info) {
    (void)action;(void)info;return d==DriverRef&&device(id)?noErr:kAudioHardwareBadObjectError;
}
static Boolean Has(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a) {
    (void)pid;if(d!=DriverRef||!a||!(id==Plugin||device(id)||stream(id)))return false;
    switch(a->mSelector) {
    case kAudioObjectPropertyBaseClass:case kAudioObjectPropertyClass:case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName:case kAudioObjectPropertyManufacturer:case kAudioObjectPropertyOwnedObjects:return true;
    }
    if(id==Plugin) switch(a->mSelector) {
    case kAudioPlugInPropertyBundleID:case kAudioPlugInPropertyDeviceList:case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioPlugInPropertyBoxList:case kAudioPlugInPropertyResourceBundle:return true;
    }
    if(device(id))switch(a->mSelector) {
    case kAudioDevicePropertyDeviceUID:case kAudioDevicePropertyModelUID:case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyRelatedDevices:case kAudioDevicePropertyClockDomain:case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:case kAudioDevicePropertyLatency:
    case kAudioDevicePropertyStreams:case kAudioObjectPropertyControlList:case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyNominalSampleRate:case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyIsHidden:case kAudioDevicePropertyPreferredChannelsForStereo:
    case kAudioDevicePropertyPreferredChannelLayout:case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioObjectPropertyCustomPropertyInfoList:case DJI_PACKET_SELECTOR:case DJI_RESET_SELECTOR:case DJI_STATUS_SELECTOR:return true;
    }
    if(stream(id))switch(a->mSelector) {
    case kAudioStreamPropertyIsActive:case kAudioStreamPropertyDirection:case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:case kAudioStreamPropertyLatency:case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:return true;
    }
    return false;
}
static OSStatus Settable(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a,Boolean *out) {
    if(!out||!Has(d,id,pid,a))return kAudioHardwareUnknownPropertyError;
    *out=(device(id)&&(a->mSelector==DJI_PACKET_SELECTOR||a->mSelector==DJI_RESET_SELECTOR))||
        a->mSelector==kAudioDevicePropertyNominalSampleRate||a->mSelector==kAudioStreamPropertyPhysicalFormat||
        a->mSelector==kAudioStreamPropertyVirtualFormat;
    return noErr;
}
static OSStatus PropertySize(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 *out) {
    (void)qs;(void)q;if(!out||!Has(d,id,pid,a))return kAudioHardwareUnknownPropertyError;
    bool input=a->mScope!=kAudioObjectPropertyScopeOutput;
    switch(a->mSelector) {
    case kAudioObjectPropertyName:case kAudioObjectPropertyManufacturer:case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:case kAudioPlugInPropertyBundleID:case kAudioPlugInPropertyResourceBundle:*out=sizeof(CFStringRef);break;
    case kAudioObjectPropertyOwnedObjects:*out=id==Plugin?2*sizeof(AudioObjectID):device(id)&&input?sizeof(AudioObjectID):0;break;
    case kAudioPlugInPropertyDeviceList:*out=2*sizeof(AudioObjectID);break;
    case kAudioPlugInPropertyBoxList:case kAudioObjectPropertyControlList:*out=0;break;
    case kAudioDevicePropertyStreams:*out=input?sizeof(AudioObjectID):0;break;
    case kAudioDevicePropertyNominalSampleRate:*out=sizeof(Float64);break;
    case kAudioDevicePropertyAvailableNominalSampleRates:*out=sizeof(AudioValueRange);break;
    case kAudioDevicePropertyPreferredChannelsForStereo:*out=2*sizeof(UInt32);break;
    case kAudioDevicePropertyPreferredChannelLayout:*out=offsetof(AudioChannelLayout,mChannelDescriptions)+DJI_CHANNELS*sizeof(AudioChannelDescription);break;
    case kAudioStreamPropertyPhysicalFormat:case kAudioStreamPropertyVirtualFormat:*out=sizeof(AudioStreamBasicDescription);break;
    case kAudioStreamPropertyAvailablePhysicalFormats:case kAudioStreamPropertyAvailableVirtualFormats:*out=sizeof(AudioStreamRangedDescription);break;
    case kAudioObjectPropertyCustomPropertyInfoList:*out=3*sizeof(AudioServerPlugInCustomPropertyInfo);break;
    case DJI_PACKET_SELECTOR:case DJI_RESET_SELECTOR:case DJI_STATUS_SELECTOR:*out=sizeof(CFPropertyListRef);break;
    default:*out=sizeof(UInt32);break;
    }
    return noErr;
}
static OSStatus Get(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 capacity,UInt32 *used,void *out) {
    UInt32 size=0;OSStatus error=PropertySize(d,id,pid,a,qs,q,&size);if(error)return error;
    if(!used||capacity<size||(size&&!out))return kAudioHardwareBadPropertySizeError;
    *used=size;if(size)memset(out,0,size);
    int n=slot(id);bool input=a->mScope!=kAudioObjectPropertyScopeOutput;
    UInt32 u32=0;CFStringRef text=NULL;
    switch(a->mSelector) {
    case kAudioObjectPropertyBaseClass:u32=kAudioObjectClassID;break;
    case kAudioObjectPropertyClass:u32=id==Plugin?kAudioPlugInClassID:device(id)?kAudioDeviceClassID:kAudioStreamClassID;break;
    case kAudioObjectPropertyOwner:u32=id==Plugin?kAudioObjectUnknown:device(id)?Plugin:n?DeviceB:DeviceA;break;
    case kAudioObjectPropertyName:text=id==Plugin?CFSTR("DJI Mic Inputs"):name(n);break;
    case kAudioObjectPropertyManufacturer:text=CFSTR("DJI Mic Workspace");break;
    case kAudioPlugInPropertyBundleID:text=CFSTR("local.dji-mic.inputs.driver");break;
    case kAudioPlugInPropertyResourceBundle:text=CFSTR("");break;
    case kAudioDevicePropertyDeviceUID:text=uid(n);break;
    case kAudioDevicePropertyModelUID:text=CFSTR("local.dji-mic.inputs.model");break;
    case kAudioPlugInPropertyTranslateUIDToDevice:
        if(qs!=sizeof(CFStringRef)||!q)return kAudioHardwareBadPropertySizeError;
        if(CFEqual(*(CFStringRef const*)q,uid(0)))u32=DeviceA;else if(CFEqual(*(CFStringRef const*)q,uid(1)))u32=DeviceB;break;
    case kAudioPlugInPropertyDeviceList:case kAudioObjectPropertyOwnedObjects:
        if(id==Plugin){((AudioObjectID*)out)[0]=DeviceA;((AudioObjectID*)out)[1]=DeviceB;return noErr;}
        if(device(id)&&input)u32=n?StreamB:StreamA;break;
    case kAudioDevicePropertyRelatedDevices:u32=id;break;
    case kAudioDevicePropertyTransportType:u32=kAudioDeviceTransportTypeVirtual;break;
    case kAudioDevicePropertyClockDomain:u32=0;break;
    case kAudioDevicePropertyDeviceIsAlive:u32=1;break;
    case kAudioDevicePropertyDeviceIsRunning:pthread_mutex_lock(&StateLock);u32=Running[n]>0;pthread_mutex_unlock(&StateLock);break;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:u32=input;break;
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:u32=0;break;
    case kAudioDevicePropertyLatency:u32=input?DJI_DELAY_FRAMES:0;break;
    case kAudioDevicePropertyStreams:if(input)u32=n?StreamB:StreamA;break;
    case kAudioDevicePropertyNominalSampleRate:*(Float64*)out=DJI_SAMPLE_RATE;return noErr;
    case kAudioDevicePropertyAvailableNominalSampleRates:*(AudioValueRange*)out=(AudioValueRange){DJI_SAMPLE_RATE,DJI_SAMPLE_RATE};return noErr;
    case kAudioDevicePropertyPreferredChannelsForStereo:((UInt32*)out)[0]=1;((UInt32*)out)[1]=2;return noErr;
    case kAudioDevicePropertyPreferredChannelLayout:{
        AudioChannelLayout *l=out;l->mChannelLayoutTag=kAudioChannelLayoutTag_UseChannelDescriptions;l->mNumberChannelDescriptions=DJI_CHANNELS;
        for(unsigned i=0;i<DJI_CHANNELS;i++)l->mChannelDescriptions[i].mChannelLabel=kAudioChannelLabel_Discrete_0+i;return noErr;}
    case kAudioDevicePropertyZeroTimeStampPeriod:u32=512;break;
    case kAudioStreamPropertyIsActive:u32=1;break;
    case kAudioStreamPropertyDirection:u32=1;break;
    case kAudioStreamPropertyTerminalType:u32=kAudioStreamTerminalTypeMicrophone;break;
    case kAudioStreamPropertyStartingChannel:u32=1;break;
    case kAudioStreamPropertyPhysicalFormat:case kAudioStreamPropertyVirtualFormat:*(AudioStreamBasicDescription*)out=format();return noErr;
    case kAudioStreamPropertyAvailablePhysicalFormats:case kAudioStreamPropertyAvailableVirtualFormats:
        *(AudioStreamRangedDescription*)out=(AudioStreamRangedDescription){format(),{DJI_SAMPLE_RATE,DJI_SAMPLE_RATE}};return noErr;
    case kAudioObjectPropertyCustomPropertyInfoList:{
        AudioServerPlugInCustomPropertyInfo *p=out;
        p[0]=(AudioServerPlugInCustomPropertyInfo){DJI_PACKET_SELECTOR,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone};
        p[1]=(AudioServerPlugInCustomPropertyInfo){DJI_RESET_SELECTOR,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone};
        p[2]=(AudioServerPlugInCustomPropertyInfo){DJI_STATUS_SELECTOR,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone};return noErr;}
    case DJI_STATUS_SELECTOR:pthread_mutex_lock(&WriteLocks[n]);*(CFDataRef*)out=CFDataCreate(NULL,(const UInt8*)&Stats[n],sizeof(DJIStatus));pthread_mutex_unlock(&WriteLocks[n]);return noErr;
    case DJI_PACKET_SELECTOR:case DJI_RESET_SELECTOR:*(CFDataRef*)out=CFDataCreate(NULL,NULL,0);return noErr;
    default:break;
    }
    if(text){*(CFStringRef*)out=text;CFRetain(text);}else if(size==sizeof(UInt32))*(UInt32*)out=u32;
    return noErr;
}
static OSStatus Set(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 size,const void *data) {
    (void)qs;(void)q;Boolean writable=false;OSStatus status=Settable(d,id,pid,a,&writable);if(status)return status;
    if(!writable)return kAudioHardwareUnsupportedOperationError;
    if(!data)return kAudioHardwareBadPropertySizeError;
    int n=slot(id);
    if(a->mSelector==DJI_PACKET_SELECTOR||a->mSelector==DJI_RESET_SELECTOR){
        if(size!=sizeof(CFPropertyListRef))return kAudioHardwareBadPropertySizeError;
        CFDataRef payload=*(CFDataRef const*)data;
        if(!payload||CFGetTypeID(payload)!=CFDataGetTypeID())return kAudioHardwareIllegalOperationError;
        size=(UInt32)CFDataGetLength(payload);data=CFDataGetBytePtr(payload);
    }
    if(a->mSelector==DJI_RESET_SELECTOR){if(size!=sizeof(UInt32))return kAudioHardwareBadPropertySizeError;
        pthread_mutex_lock(&WriteLocks[n]);DJIReset(&Rings[n]);Stats[n].resets++;pthread_mutex_unlock(&WriteLocks[n]);return noErr;}
    if(a->mSelector==DJI_PACKET_SELECTOR){
        const DJIPacket *p=data;if(!DJIValidPacket(p,size))return kAudioHardwareBadPropertySizeError;
        uint64_t now=mach_absolute_time();
        if(fabs((double)p->hostTime-(double)now)>HostFrequency*2)return kAudioHardwareIllegalOperationError;
        pthread_mutex_lock(&WriteLocks[n]);DJIWrite(&Rings[n],p,HostFrequency);Stats[n].packets++;Stats[n].frames+=p->frames;Stats[n].lastHostTime=p->hostTime;pthread_mutex_unlock(&WriteLocks[n]);return noErr;}
    if(a->mSelector==kAudioDevicePropertyNominalSampleRate)return size==sizeof(Float64)&&*(const Float64*)data==DJI_SAMPLE_RATE?noErr:kAudioDeviceUnsupportedFormatError;
    if(a->mSelector==kAudioStreamPropertyPhysicalFormat||a->mSelector==kAudioStreamPropertyVirtualFormat){
        if(size!=sizeof(AudioStreamBasicDescription))return kAudioHardwareBadPropertySizeError;
        AudioStreamBasicDescription expected=format();return memcmp(data,&expected,sizeof(expected))==0?noErr:kAudioDeviceUnsupportedFormatError;}
    return kAudioHardwareUnknownPropertyError;
}
static OSStatus Start(AudioServerPlugInDriverRef d,AudioObjectID id,UInt32 client) {
    (void)client;if(d!=DriverRef||!device(id))return kAudioHardwareBadObjectError;
    int n=slot(id);pthread_mutex_lock(&StateLock);if(Running[n]++==0){Anchors[n]=mach_absolute_time();Seeds[n]++;}pthread_mutex_unlock(&StateLock);return noErr;
}
static OSStatus Stop(AudioServerPlugInDriverRef d,AudioObjectID id,UInt32 client) {
    (void)client;if(d!=DriverRef||!device(id))return kAudioHardwareBadObjectError;
    int n=slot(id);pthread_mutex_lock(&StateLock);if(Running[n])Running[n]--;pthread_mutex_unlock(&StateLock);return noErr;
}
static OSStatus Zero(AudioServerPlugInDriverRef d,AudioObjectID id,UInt32 client,Float64 *sample,UInt64 *host,UInt64 *seed) {
    (void)client;if(d!=DriverRef||!device(id)||!sample||!host||!seed)return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&StateLock);uint64_t anchor=Anchors[slot(id)],currentSeed=Seeds[slot(id)];pthread_mutex_unlock(&StateLock);
    double period=HostFrequency/DJI_SAMPLE_RATE*512;
    uint64_t count=(uint64_t)((mach_absolute_time()-anchor)/period);
    *sample=count*512;*host=anchor+(uint64_t)(count*period);*seed=currentSeed;return noErr;
}
static OSStatus Will(AudioServerPlugInDriverRef d,AudioObjectID id,UInt32 client,UInt32 op,Boolean *will,Boolean *inPlace) {
    (void)client;if(d!=DriverRef||!device(id)||!will||!inPlace)return kAudioHardwareBadObjectError;
    *will=op==kAudioServerPlugInIOOperationReadInput;*inPlace=true;return noErr;
}
static OSStatus Cycle(AudioServerPlugInDriverRef d,AudioObjectID id,UInt32 client,UInt32 op,UInt32 frames,const AudioServerPlugInIOCycleInfo *info) {
    (void)client;(void)op;(void)frames;(void)info;return d==DriverRef&&device(id)?noErr:kAudioHardwareBadObjectError;
}
static OSStatus IO(AudioServerPlugInDriverRef d,AudioObjectID id,AudioObjectID streamID,UInt32 client,UInt32 op,UInt32 frames,const AudioServerPlugInIOCycleInfo *info,void *buffer,void *other) {
    (void)client;(void)other;
    if(d!=DriverRef||!device(id)||streamID!=(id==DeviceA?StreamA:StreamB)||!buffer||!info)return kAudioHardwareBadObjectError;
    if(op!=kAudioServerPlugInIOOperationReadInput)return noErr;
    double first=(double)info->mInputTime.mHostTime*DJI_SAMPLE_RATE/HostFrequency-DJI_DELAY_FRAMES;
    if(first<0){memset(buffer,0,(size_t)frames*16);return noErr;}
    DJIRead(&Rings[slot(id)],(uint64_t)llround(first),frames,buffer);return noErr;
}
static AudioServerPlugInDriverInterface Interface={NULL,Query,AddRef,Release,Initialize,CreateDevice,DestroyDevice,Client,Client,Config,Config,Has,Settable,PropertySize,Get,Set,Start,Stop,Zero,Will,Cycle,IO,Cycle};
__attribute__((visibility("default"))) void *DJIMicFactory(CFAllocatorRef allocator,CFUUIDRef type) {
    (void)allocator;return CFEqual(type,kAudioServerPlugInTypeUUID)?DriverRef:NULL;
}
