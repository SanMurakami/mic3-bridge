/* AudioServerPlugIn のインターフェイス構成は Apple NullAudio サンプルを参考にした。
 * Apple のライセンスは ../vendor/apple-null-audio/LICENSE.txt に保持する。 */
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <string.h>
#include "Timeline.h"

enum { Plugin=1 };
static AudioServerPlugInDriverInterface Interface;
static AudioServerPlugInDriverInterface *InterfacePtr=&Interface;
static AudioServerPlugInDriverRef DriverRef=&InterfacePtr;
static AudioServerPlugInHostRef Host;
static bool Ready=false;
static _Atomic unsigned RefCount=1;
typedef struct DeviceNode DeviceNode;
typedef struct {DeviceNode *source;unsigned channel;} Route;
typedef struct {unsigned count;Route channels[];} RoutePlan;
struct DeviceNode {
    AudioObjectID id;
    _Atomic bool active;
    unsigned channels;
    CFStringRef name,uid;
    DJITimeline *ring;
    _Atomic(RoutePlan*) routes;
    CFArrayRef routeDescription;
    DJIStatus stats;
    pthread_mutex_t writeLock;
    uint64_t running,anchor,seed;
    struct DeviceNode *next;
};
static _Atomic(DeviceNode*) Devices;
static unsigned NextID=100;
static pthread_mutex_t StateLock=PTHREAD_MUTEX_INITIALIZER;
static double HostFrequency;
static DeviceNode *slot(AudioObjectID id) {
    for(DeviceNode *n=atomic_load(&Devices);n;n=n->next)if(n->id==id||n->id+1==id)return n;
    return NULL;
}
static int device(AudioObjectID id) {DeviceNode *n=slot(id);return n&&n->id==id;}
static int stream(AudioObjectID id) {DeviceNode *n=slot(id);return n&&n->id+1==id;}
static CFStringRef uid(DeviceNode *n) {return n->uid;}
static unsigned countDevices(void){unsigned count=0;for(DeviceNode *n=atomic_load(&Devices);n;n=n->next)if(atomic_load(&n->active))count++;return count;}
static CFArrayRef description(void) {
    CFMutableArrayRef result=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    for(DeviceNode *n=atomic_load(&Devices);n;n=n->next){
        if(!atomic_load(&n->active))continue;
        CFNumberRef channels=CFNumberCreate(NULL,kCFNumberIntType,&n->channels);
        const void *keys[]={CFSTR("uid"),CFSTR("name"),CFSTR("channels")},*values[]={n->uid,n->name,channels};
        CFMutableDictionaryRef row=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);for(int i=0;i<3;i++)CFDictionarySetValue(row,keys[i],values[i]);if(n->routeDescription)CFDictionarySetValue(row,CFSTR("routes"),n->routeDescription);CFArrayAppendValue(result,row);CFRelease(row);CFRelease(channels);
    }
    return result;
}
static unsigned configuredChannels(CFDictionaryRef row){CFNumberRef value=CFDictionaryGetValue(row,CFSTR("channels"));int count=4;
    if(value&&(CFGetTypeID(value)!=CFNumberGetTypeID()||!CFNumberGetValue(value,kCFNumberIntType,&count)))return 0;
    return count>=4&&count<=64&&count%4==0?(unsigned)count:0;
}
static OSStatus configure(CFArrayRef rows) {
    if(!rows||CFGetTypeID(rows)!=CFArrayGetTypeID())return kAudioHardwareIllegalOperationError;
    // 入力全体を確認してから公開する。削除は行わず、USB 切断中もデバイスを維持する。
    for(CFIndex i=0;i<CFArrayGetCount(rows);i++){
        CFDictionaryRef row=CFArrayGetValueAtIndex(rows,i);if(CFGetTypeID(row)!=CFDictionaryGetTypeID())return kAudioHardwareIllegalOperationError;
        CFStringRef id=CFDictionaryGetValue(row,CFSTR("uid")),label=CFDictionaryGetValue(row,CFSTR("name"));
        if(!id||!label||CFGetTypeID(id)!=CFStringGetTypeID()||CFGetTypeID(label)!=CFStringGetTypeID()||
           !configuredChannels(row)||CFStringGetLength(id)>128||CFStringGetLength(label)>128||!CFStringGetLength(label)||!CFStringHasPrefix(id,CFSTR("local.dji-mic.input.")))return kAudioHardwareIllegalOperationError;
        if(!CFEqual(id,CFSTR(DJI_BUS_UID))&&configuredChannels(row)!=4)return kAudioHardwareIllegalOperationError;
        CFArrayRef routes=CFDictionaryGetValue(row,CFSTR("routes"));
        if(routes&&CFGetTypeID(routes)!=CFNullGetTypeID()){
            if(!CFEqual(id,CFSTR(DJI_BUS_UID))||CFGetTypeID(routes)!=CFArrayGetTypeID()||CFArrayGetCount(routes)!=configuredChannels(row))return kAudioHardwareIllegalOperationError;
            for(CFIndex ch=0;ch<CFArrayGetCount(routes);ch++){CFTypeRef entry=CFArrayGetValueAtIndex(routes,ch);if(CFGetTypeID(entry)==CFDictionaryGetTypeID()&&CFDictionaryGetCount(entry)==0)continue;
                if(CFGetTypeID(entry)!=CFDictionaryGetTypeID())return kAudioHardwareIllegalOperationError;
                CFStringRef source=CFDictionaryGetValue(entry,CFSTR("uid"));CFNumberRef number=CFDictionaryGetValue(entry,CFSTR("channel"));int value=-1;
                if(!source||CFGetTypeID(source)!=CFStringGetTypeID()||CFEqual(source,id)||!number||CFGetTypeID(number)!=CFNumberGetTypeID()||!CFNumberGetValue(number,kCFNumberIntType,&value)||value<0||value>3)return kAudioHardwareIllegalOperationError;
            }
        }
    }
    bool changed=false;OSStatus result=noErr;
    pthread_mutex_lock(&StateLock);
    for(CFIndex i=0;i<CFArrayGetCount(rows);i++){
        CFDictionaryRef row=CFArrayGetValueAtIndex(rows,i);CFStringRef id=CFDictionaryGetValue(row,CFSTR("uid")),label=CFDictionaryGetValue(row,CFSTR("name"));
        DeviceNode *n=atomic_load(&Devices);while(n&&(!atomic_load(&n->active)||!CFEqual(n->uid,id)))n=n->next;
        if(n){if(n->channels!=configuredChannels(row)){result=kAudioHardwareIllegalOperationError;break;}if(!CFEqual(n->name,label)){CFRetain(label);CFRelease(n->name);n->name=label;changed=true;}continue;}
        n=calloc(1,sizeof(*n));if(!n){result=kAudioHardwareUnspecifiedError;break;}
        n->channels=configuredChannels(row);n->ring=calloc(1,sizeof(DJITimeline));if(!n->ring){free(n);result=kAudioHardwareUnspecifiedError;break;}
        for(unsigned f=0;f<DJI_RING_FRAMES;f++){atomic_init(&n->ring->frames[f].tag,0);for(unsigned c=0;c<DJI_CHANNELS;c++)atomic_init(&n->ring->frames[f].samples[c],0);}
        atomic_init(&n->active,true);n->id=NextID;NextID+=2;n->seed=1;n->uid=CFRetain(id);n->name=CFRetain(label);pthread_mutex_init(&n->writeLock,NULL);
        n->next=atomic_load(&Devices);atomic_store(&Devices,n);changed=true;
    }
    if(!result)for(CFIndex i=0;i<CFArrayGetCount(rows);i++){
        CFDictionaryRef row=CFArrayGetValueAtIndex(rows,i);CFStringRef id=CFDictionaryGetValue(row,CFSTR("uid"));
        if(!CFEqual(id,CFSTR(DJI_BUS_UID)))continue;
        DeviceNode *bus=atomic_load(&Devices);while(bus&&(!atomic_load(&bus->active)||!CFEqual(bus->uid,id)))bus=bus->next;
        CFArrayRef routes=CFDictionaryGetValue(row,CFSTR("routes"));if(!routes||CFGetTypeID(routes)!=CFArrayGetTypeID())continue;
        RoutePlan *plan=calloc(1,sizeof(*plan)+bus->channels*sizeof(Route));if(!plan){result=kAudioHardwareUnspecifiedError;break;}plan->count=bus->channels;
        for(unsigned ch=0;ch<plan->count;ch++){CFTypeRef entry=CFArrayGetValueAtIndex(routes,ch);if(CFGetTypeID(entry)==CFDictionaryGetTypeID()&&CFDictionaryGetCount(entry)==0)continue;
            CFStringRef source=CFDictionaryGetValue(entry,CFSTR("uid"));int value=0;CFNumberGetValue(CFDictionaryGetValue(entry,CFSTR("channel")),kCFNumberIntType,&value);
            for(DeviceNode *n=atomic_load(&Devices);n;n=n->next)if(atomic_load(&n->active)&&n->channels==4&&CFEqual(n->uid,source)){plan->channels[ch]=(Route){n,(unsigned)value};break;}
        }
        // 旧 plan も callback 完了前には解放しない（小さな設定オブジェクトのみ保持）。
        atomic_store(&bus->routes,plan);if(bus->routeDescription)CFRelease(bus->routeDescription);bus->routeDescription=CFRetain(routes);
    }
    CFArrayRef saved=description();pthread_mutex_unlock(&StateLock);
    if(Host&&Ready){Host->WriteToStorage(Host,CFSTR("registered-receivers-v2"),saved);
        if(changed){AudioObjectPropertyAddress addresses[]={{kAudioPlugInPropertyDeviceList,kAudioObjectPropertyScopeGlobal,0},{kAudioObjectPropertyOwnedObjects,kAudioObjectPropertyScopeGlobal,0}};
            Host->PropertiesChanged(Host,Plugin,2,addresses);
            for(DeviceNode *n=atomic_load(&Devices);n;n=n->next){AudioObjectPropertyAddress a={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,0};Host->PropertiesChanged(Host,n->id,1,&a);}
        }
    }
    CFRelease(saved);return result;
}
// 公開一覧から取り除くが、進行中の callback が参照するノードを解放しない。
// 旧 ID の読者には無音、再登録は新しい object ID と同じ UID になる。
static OSStatus removeReceiver(CFStringRef id) {
    if(!id||CFGetTypeID(id)!=CFStringGetTypeID())return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&StateLock);DeviceNode *removed=NULL;
    for(DeviceNode *n=atomic_load(&Devices);n;n=n->next)if(atomic_load(&n->active)&&CFEqual(n->uid,id)){if(n->running){pthread_mutex_unlock(&StateLock);return kAudioHardwareIllegalOperationError;}atomic_store(&n->active,false);removed=n;break;}
    CFArrayRef saved=description();pthread_mutex_unlock(&StateLock);
    if(Host&&Ready){OSStatus error=Host->WriteToStorage(Host,CFSTR("registered-receivers-v2"),saved);
        if(error){if(removed)atomic_store(&removed->active,true);CFRelease(saved);return error;}
        if(removed){AudioObjectPropertyAddress alive={kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,0};Host->PropertiesChanged(Host,removed->id,1,&alive);
            AudioObjectPropertyAddress list[]={{kAudioPlugInPropertyDeviceList,kAudioObjectPropertyScopeGlobal,0},{kAudioObjectPropertyOwnedObjects,kAudioObjectPropertyScopeGlobal,0}};Host->PropertiesChanged(Host,Plugin,2,list);}}
    CFRelease(saved);return noErr;
}
static AudioStreamBasicDescription format(unsigned channels) {
    return (AudioStreamBasicDescription){.mSampleRate=DJI_SAMPLE_RATE,.mFormatID=kAudioFormatLinearPCM,
        .mFormatFlags=kAudioFormatFlagsNativeFloatPacked,.mBytesPerPacket=channels*4,.mFramesPerPacket=1,
        .mBytesPerFrame=channels*4,.mChannelsPerFrame=channels,.mBitsPerChannel=32};
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
    if(d!=DriverRef)return kAudioHardwareBadObjectError;
    mach_timebase_info_data_t timebase;mach_timebase_info(&timebase);
    HostFrequency=1e9*(double)timebase.denom/timebase.numer;
    Host=host;if(Host){CFPropertyListRef saved=NULL;Host->CopyFromStorage(Host,CFSTR("registered-receivers-v2"),&saved);if(saved){configure(saved);CFRelease(saved);}}
    Ready=true;return noErr;
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
    case kAudioPlugInPropertyBoxList:case kAudioPlugInPropertyResourceBundle:case kAudioObjectPropertyCustomPropertyInfoList:case DJI_DEVICES_SELECTOR:case DJI_REMOVE_SELECTOR:return true;
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
    *out=(id==Plugin&&(a->mSelector==DJI_DEVICES_SELECTOR||a->mSelector==DJI_REMOVE_SELECTOR))||(device(id)&&(a->mSelector==DJI_PACKET_SELECTOR||a->mSelector==DJI_RESET_SELECTOR))||
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
    case kAudioObjectPropertyOwnedObjects:*out=id==Plugin?countDevices()*sizeof(AudioObjectID):device(id)&&input?sizeof(AudioObjectID):0;break;
    case kAudioPlugInPropertyDeviceList:*out=countDevices()*sizeof(AudioObjectID);break;
    case kAudioPlugInPropertyBoxList:case kAudioObjectPropertyControlList:*out=0;break;
    case kAudioDevicePropertyStreams:*out=input?sizeof(AudioObjectID):0;break;
    case kAudioDevicePropertyNominalSampleRate:*out=sizeof(Float64);break;
    case kAudioDevicePropertyAvailableNominalSampleRates:*out=sizeof(AudioValueRange);break;
    case kAudioDevicePropertyPreferredChannelsForStereo:*out=2*sizeof(UInt32);break;
    case kAudioDevicePropertyPreferredChannelLayout:*out=offsetof(AudioChannelLayout,mChannelDescriptions)+slot(id)->channels*sizeof(AudioChannelDescription);break;
    case kAudioStreamPropertyPhysicalFormat:case kAudioStreamPropertyVirtualFormat:*out=sizeof(AudioStreamBasicDescription);break;
    case kAudioStreamPropertyAvailablePhysicalFormats:case kAudioStreamPropertyAvailableVirtualFormats:*out=sizeof(AudioStreamRangedDescription);break;
    case kAudioObjectPropertyCustomPropertyInfoList:*out=(id==Plugin?2:3)*sizeof(AudioServerPlugInCustomPropertyInfo);break;
    case DJI_REMOVE_SELECTOR:case DJI_DEVICES_SELECTOR:case DJI_PACKET_SELECTOR:case DJI_RESET_SELECTOR:case DJI_STATUS_SELECTOR:*out=sizeof(CFPropertyListRef);break;
    default:*out=sizeof(UInt32);break;
    }
    return noErr;
}
static OSStatus Get(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 capacity,UInt32 *used,void *out) {
    if(d==DriverRef&&a&&id==Plugin&&(a->mSelector==kAudioPlugInPropertyDeviceList||a->mSelector==kAudioObjectPropertyOwnedObjects)){
        if(!used)return kAudioHardwareBadPropertySizeError;pthread_mutex_lock(&StateLock);
        UInt32 required=countDevices()*sizeof(AudioObjectID);
        if(capacity<required||(required&&!out)){pthread_mutex_unlock(&StateLock);return kAudioHardwareBadPropertySizeError;}
        unsigned i=0;for(DeviceNode *node=atomic_load(&Devices);node;node=node->next)if(atomic_load(&node->active))((AudioObjectID*)out)[i++]=node->id;
        *used=required;pthread_mutex_unlock(&StateLock);return noErr;
    }
    UInt32 size=0;OSStatus error=PropertySize(d,id,pid,a,qs,q,&size);if(error)return error;
    if(!used||capacity<size||(size&&!out))return kAudioHardwareBadPropertySizeError;
    *used=size;if(size)memset(out,0,size);
    DeviceNode *n=slot(id);bool input=a->mScope!=kAudioObjectPropertyScopeOutput;
    UInt32 u32=0;CFStringRef text=NULL;
    switch(a->mSelector) {
    case kAudioObjectPropertyBaseClass:u32=kAudioObjectClassID;break;
    case kAudioObjectPropertyClass:u32=id==Plugin?kAudioPlugInClassID:device(id)?kAudioDeviceClassID:kAudioStreamClassID;break;
    case kAudioObjectPropertyOwner:u32=id==Plugin?kAudioObjectUnknown:device(id)?Plugin:n->id;break;
    case kAudioObjectPropertyName:pthread_mutex_lock(&StateLock);text=id==Plugin?CFSTR("DJI Mic Inputs"):n->name;CFRetain(text);*(CFStringRef*)out=text;pthread_mutex_unlock(&StateLock);return noErr;
    case kAudioObjectPropertyManufacturer:text=CFSTR("DJI Mic Workspace");break;
    case kAudioPlugInPropertyBundleID:text=CFSTR("local.dji-mic.inputs.driver");break;
    case kAudioPlugInPropertyResourceBundle:text=CFSTR("");break;
    case kAudioDevicePropertyDeviceUID:text=uid(n);break;
    case kAudioDevicePropertyModelUID:text=CFSTR("local.dji-mic.inputs.model");break;
    case kAudioPlugInPropertyTranslateUIDToDevice:
        if(qs!=sizeof(CFStringRef)||!q)return kAudioHardwareBadPropertySizeError;
        for(DeviceNode *node=atomic_load(&Devices);node;node=node->next)if(atomic_load(&node->active)&&CFEqual(*(CFStringRef const*)q,node->uid)){u32=node->id;break;}break;
    case kAudioPlugInPropertyDeviceList:case kAudioObjectPropertyOwnedObjects:
        if(id==Plugin){unsigned i=0;for(DeviceNode *node=atomic_load(&Devices);node;node=node->next)if(atomic_load(&node->active))((AudioObjectID*)out)[i++]=node->id;return noErr;}
        if(device(id)&&input)u32=n->id+1;break;
    case kAudioDevicePropertyRelatedDevices:u32=id;break;
    case kAudioDevicePropertyTransportType:u32=kAudioDeviceTransportTypeVirtual;break;
    case kAudioDevicePropertyClockDomain:u32=0;break;
    case kAudioDevicePropertyDeviceIsAlive:u32=atomic_load(&n->active);break;
    case kAudioDevicePropertyDeviceIsRunning:pthread_mutex_lock(&StateLock);u32=n->running>0;pthread_mutex_unlock(&StateLock);break;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:u32=input;break;
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:u32=0;break;
    case kAudioDevicePropertyLatency:u32=input?DJI_DELAY_FRAMES:0;break;
    case kAudioDevicePropertyStreams:if(input)u32=n->id+1;break;
    case kAudioDevicePropertyNominalSampleRate:*(Float64*)out=DJI_SAMPLE_RATE;return noErr;
    case kAudioDevicePropertyAvailableNominalSampleRates:*(AudioValueRange*)out=(AudioValueRange){DJI_SAMPLE_RATE,DJI_SAMPLE_RATE};return noErr;
    case kAudioDevicePropertyPreferredChannelsForStereo:((UInt32*)out)[0]=1;((UInt32*)out)[1]=2;return noErr;
    case kAudioDevicePropertyPreferredChannelLayout:{
        AudioChannelLayout *l=out;l->mChannelLayoutTag=kAudioChannelLayoutTag_UseChannelDescriptions;l->mNumberChannelDescriptions=n->channels;
        for(unsigned i=0;i<n->channels;i++)l->mChannelDescriptions[i].mChannelLabel=kAudioChannelLabel_Discrete_0+i;return noErr;}
    case kAudioDevicePropertyZeroTimeStampPeriod:u32=512;break;
    case kAudioStreamPropertyIsActive:u32=1;break;
    case kAudioStreamPropertyDirection:u32=1;break;
    case kAudioStreamPropertyTerminalType:u32=kAudioStreamTerminalTypeMicrophone;break;
    case kAudioStreamPropertyStartingChannel:u32=1;break;
    case kAudioStreamPropertyPhysicalFormat:case kAudioStreamPropertyVirtualFormat:*(AudioStreamBasicDescription*)out=format(n->channels);return noErr;
    case kAudioStreamPropertyAvailablePhysicalFormats:case kAudioStreamPropertyAvailableVirtualFormats:
        *(AudioStreamRangedDescription*)out=(AudioStreamRangedDescription){format(n->channels),{DJI_SAMPLE_RATE,DJI_SAMPLE_RATE}};return noErr;
    case kAudioObjectPropertyCustomPropertyInfoList:{
        AudioServerPlugInCustomPropertyInfo *p=out;
        if(id==Plugin){p[1]=(AudioServerPlugInCustomPropertyInfo){DJI_REMOVE_SELECTOR,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone};p[0]=(AudioServerPlugInCustomPropertyInfo){DJI_DEVICES_SELECTOR,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone};return noErr;}
        p[0]=(AudioServerPlugInCustomPropertyInfo){DJI_PACKET_SELECTOR,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone};
        p[1]=(AudioServerPlugInCustomPropertyInfo){DJI_RESET_SELECTOR,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone};
        p[2]=(AudioServerPlugInCustomPropertyInfo){DJI_STATUS_SELECTOR,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone};return noErr;}
    case DJI_DEVICES_SELECTOR:pthread_mutex_lock(&StateLock);*(CFArrayRef*)out=description();pthread_mutex_unlock(&StateLock);return noErr;
    case DJI_STATUS_SELECTOR:pthread_mutex_lock(&n->writeLock);*(CFDataRef*)out=CFDataCreate(NULL,(const UInt8*)&n->stats,sizeof(DJIStatus));pthread_mutex_unlock(&n->writeLock);return noErr;
    case DJI_REMOVE_SELECTOR:case DJI_PACKET_SELECTOR:case DJI_RESET_SELECTOR:*(CFDataRef*)out=CFDataCreate(NULL,NULL,0);return noErr;
    default:break;
    }
    if(text){*(CFStringRef*)out=text;CFRetain(text);}else if(size==sizeof(UInt32))*(UInt32*)out=u32;
    return noErr;
}
static OSStatus Set(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 qs,const void *q,UInt32 size,const void *data) {
    (void)qs;(void)q;Boolean writable=false;OSStatus status=Settable(d,id,pid,a,&writable);if(status)return status;
    if(!writable)return kAudioHardwareUnsupportedOperationError;
    if(!data)return kAudioHardwareBadPropertySizeError;
    DeviceNode *n=slot(id);
    if(a->mSelector==DJI_REMOVE_SELECTOR){if(size!=sizeof(CFPropertyListRef))return kAudioHardwareBadPropertySizeError;return removeReceiver(*(CFStringRef const*)data);}
    if(a->mSelector==DJI_DEVICES_SELECTOR){if(size!=sizeof(CFPropertyListRef))return kAudioHardwareBadPropertySizeError;return configure(*(CFArrayRef const*)data);}
    if(a->mSelector==DJI_PACKET_SELECTOR||a->mSelector==DJI_RESET_SELECTOR){
        if(size!=sizeof(CFPropertyListRef))return kAudioHardwareBadPropertySizeError;
        CFDataRef payload=*(CFDataRef const*)data;
        if(!payload||CFGetTypeID(payload)!=CFDataGetTypeID())return kAudioHardwareIllegalOperationError;
        size=(UInt32)CFDataGetLength(payload);data=CFDataGetBytePtr(payload);
    }
    if(a->mSelector==DJI_RESET_SELECTOR){if(size!=sizeof(UInt32))return kAudioHardwareBadPropertySizeError;
        pthread_mutex_lock(&n->writeLock);DJIReset(n->ring);n->stats.resets++;pthread_mutex_unlock(&n->writeLock);return noErr;}
    if(a->mSelector==DJI_PACKET_SELECTOR){
        if(!atomic_load(&n->active))return kAudioHardwareIllegalOperationError;
        const DJIPacket *p=data;if(!DJIValidPacket(p,size)||p->reserved!=0||CFEqual(n->uid,CFSTR(DJI_BUS_UID)))return kAudioHardwareBadPropertySizeError;
        uint64_t now=mach_absolute_time();
        if(fabs((double)p->hostTime-(double)now)>HostFrequency*2)return kAudioHardwareIllegalOperationError;
        pthread_mutex_lock(&n->writeLock);DJIWrite(n->ring,p,HostFrequency);n->stats.packets++;n->stats.frames+=p->frames;n->stats.lastHostTime=p->hostTime;pthread_mutex_unlock(&n->writeLock);return noErr;}
    if(a->mSelector==kAudioDevicePropertyNominalSampleRate)return size==sizeof(Float64)&&*(const Float64*)data==DJI_SAMPLE_RATE?noErr:kAudioDeviceUnsupportedFormatError;
    if(a->mSelector==kAudioStreamPropertyPhysicalFormat||a->mSelector==kAudioStreamPropertyVirtualFormat){
        if(size!=sizeof(AudioStreamBasicDescription))return kAudioHardwareBadPropertySizeError;
        AudioStreamBasicDescription expected=format(n->channels);return memcmp(data,&expected,sizeof(expected))==0?noErr:kAudioDeviceUnsupportedFormatError;}
    return kAudioHardwareUnknownPropertyError;
}
static OSStatus Start(AudioServerPlugInDriverRef d,AudioObjectID id,UInt32 client) {
    (void)client;if(d!=DriverRef||!device(id))return kAudioHardwareBadObjectError;
    DeviceNode *n=slot(id);pthread_mutex_lock(&StateLock);if(!atomic_load(&n->active)){pthread_mutex_unlock(&StateLock);return kAudioHardwareIllegalOperationError;}bool first=n->running++==0;if(first){n->anchor=mach_absolute_time();n->seed++;}pthread_mutex_unlock(&StateLock);
    if(first&&Host)dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{AudioObjectPropertyAddress a={kAudioDevicePropertyDeviceIsRunning,kAudioObjectPropertyScopeGlobal,0};Host->PropertiesChanged(Host,id,1,&a);});return noErr;
}
static OSStatus Stop(AudioServerPlugInDriverRef d,AudioObjectID id,UInt32 client) {
    (void)client;if(d!=DriverRef||!device(id))return kAudioHardwareBadObjectError;
    DeviceNode *n=slot(id);pthread_mutex_lock(&StateLock);bool last=n->running&&--n->running==0;pthread_mutex_unlock(&StateLock);
    if(last&&Host)dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{AudioObjectPropertyAddress a={kAudioDevicePropertyDeviceIsRunning,kAudioObjectPropertyScopeGlobal,0};Host->PropertiesChanged(Host,id,1,&a);});return noErr;
}
static OSStatus Zero(AudioServerPlugInDriverRef d,AudioObjectID id,UInt32 client,Float64 *sample,UInt64 *host,UInt64 *seed) {
    (void)client;if(d!=DriverRef||!device(id)||!sample||!host||!seed)return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&StateLock);DeviceNode *n=slot(id);uint64_t anchor=n->anchor,currentSeed=n->seed;pthread_mutex_unlock(&StateLock);
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
    if(d!=DriverRef||!device(id)||streamID!=id+1||!buffer||!info)return kAudioHardwareBadObjectError;
    if(op!=kAudioServerPlugInIOOperationReadInput)return noErr;
    if(!atomic_load(&slot(id)->active)){memset(buffer,0,(size_t)frames*slot(id)->channels*sizeof(float));return noErr;}
    double first=(double)info->mInputTime.mHostTime*DJI_SAMPLE_RATE/HostFrequency-DJI_DELAY_FRAMES;
    if(first<0){memset(buffer,0,(size_t)frames*slot(id)->channels*sizeof(float));return noErr;}
    DeviceNode *n=slot(id);RoutePlan *plan=atomic_load(&n->routes);
    if(plan){memset(buffer,0,(size_t)frames*n->channels*sizeof(float));for(unsigned ch=0;ch<plan->count;ch++){Route r=plan->channels[ch];if(r.source&&atomic_load(&r.source->active))DJIReadChannel(r.source->ring,(uint64_t)llround(first),frames,buffer,n->channels,ch,r.channel);}}
    else if(n->channels==4&&!CFEqual(n->uid,CFSTR(DJI_BUS_UID)))DJIRead(n->ring,(uint64_t)llround(first),frames,buffer);
    else memset(buffer,0,(size_t)frames*n->channels*sizeof(float));return noErr;
}
static AudioServerPlugInDriverInterface Interface={NULL,Query,AddRef,Release,Initialize,CreateDevice,DestroyDevice,Client,Client,Config,Config,Has,Settable,PropertySize,Get,Set,Start,Stop,Zero,Will,Cycle,IO,Cycle};
__attribute__((visibility("default"))) void *DJIMicFactory(CFAllocatorRef allocator,CFUUIDRef type) {
    (void)allocator;return CFEqual(type,kAudioServerPlugInTypeUUID)?DriverRef:NULL;
}
