#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include <CoreAudio/CoreAudio.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <sys/file.h>
#include <signal.h>
#include <unistd.h>
#include <atomic>
#include <array>
#include <chrono>
#include <thread>
#include <memory>
#include <stdexcept>
#include <iostream>
#include "Resolver.hpp"
#include "../driver/Protocol.h"

static std::atomic<bool> Running(true),Dirty(true);
static void signalStop(int){Running=false;}
static AudioObjectPropertyAddress addr(AudioObjectPropertySelector selector,AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal) {
    return {selector,scope,kAudioObjectPropertyElementMain};
}
static void check(OSStatus status,const char *what){if(status)throw std::runtime_error(std::string(what)+": OSStatus "+std::to_string(status));}
static std::string text(AudioObjectID id,AudioObjectPropertySelector s) {
    auto a=addr(s);CFStringRef value=nullptr;UInt32 bytes=sizeof(value);
    if(AudioObjectGetPropertyData(id,&a,0,nullptr,&bytes,&value)||!value)return "";
    NSString *ns=CFBridgingRelease(value);return ns.UTF8String?:"";
}
static std::vector<dji::Audio> audioDevices(bool physicalOnly) {
    auto a=addr(kAudioHardwarePropertyDevices);UInt32 bytes=0;
    check(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,nullptr,&bytes),"device size");
    std::vector<AudioObjectID> ids(bytes/sizeof(AudioObjectID));
    check(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,nullptr,&bytes,ids.data()),"devices");
    std::vector<dji::Audio> result;
    for(auto id:ids){auto uid=text(id,kAudioDevicePropertyDeviceUID);
        if(!physicalOnly||uid.find("AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:")==0)result.push_back({id,uid});}
    return result;
}
static std::vector<dji::USB> usbDevices() {
    io_iterator_t iterator=0;std::vector<dji::USB> result;
    if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&iterator)!=KERN_SUCCESS)return result;
    io_service_t service;
    while((service=IOIteratorNext(iterator))) {
        CFMutableDictionaryRef props=nullptr;
        if(IORegistryEntryCreateCFProperties(service,&props,kCFAllocatorDefault,0)==KERN_SUCCESS) {
            NSDictionary *dict=CFBridgingRelease(props);
            if([dict[@"idVendor"] unsignedIntValue]==0x2ca3&&[dict[@"USB Product Name"] isEqual:@"Wireless Mic Rx"])
                result.push_back({[dict[@"locationID"] unsignedIntValue],[(NSString*)dict[@"USB Serial Number"] UTF8String]?:""});
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);return result;
}
static OSStatus changed(AudioObjectID,UInt32,const AudioObjectPropertyAddress*,void*) {Dirty=true;return noErr;}
static double hostFrequency() {mach_timebase_info_data_t t;mach_timebase_info(&t);return 1e9*(double)t.denom/t.numer;}
static void reset(AudioObjectID id) {
    auto a=addr(DJI_RESET_SELECTOR);UInt32 value=1;
    CFDataRef payload=CFDataCreate(NULL,(const UInt8*)&value,sizeof(value));
    AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(payload),&payload);CFRelease(payload);
}
struct Config {uint32_t location;std::string uid,name;};

struct Session {
    static constexpr unsigned QueueSize=32;
    AudioObjectID source,target;AudioDeviceIOProcID proc=nullptr;
    AudioStreamBasicDescription format{};
    std::array<DJIPacket,QueueSize> queue{};
    std::atomic<uint64_t> write{0},read{0},dropped{0},lastCallback{0},received{0};
    uint64_t sent=0;OSStatus lastError=0;
    double frequency;
    bool started=false;
    Session(AudioObjectID source,AudioObjectID target):source(source),target(target),frequency(hostFrequency()) {
        auto a=addr(kAudioDevicePropertyStreamFormat,kAudioObjectPropertyScopeInput);UInt32 bytes=sizeof(format);
        check(AudioObjectGetPropertyData(source,&a,0,nullptr,&bytes,&format),"input format");
        if(format.mFormatID!=kAudioFormatLinearPCM||!(format.mFormatFlags&kAudioFormatFlagIsFloat)||
           format.mBitsPerChannel!=32||(format.mFormatFlags&kAudioFormatFlagIsBigEndian)||
           format.mChannelsPerFrame<1||format.mChannelsPerFrame>4||format.mSampleRate<8000||format.mSampleRate>48000)
            throw std::runtime_error("未対応の入力形式（Float32、1〜4ch が必要）");
    }
    static OSStatus capture(AudioObjectID,const AudioTimeStamp*,const AudioBufferList *in,const AudioTimeStamp *time,AudioBufferList*,const AudioTimeStamp*,void *context) {
        auto& self=*(Session*)context;
        self.lastCallback=mach_absolute_time();
        if(!in||!time||!(time->mFlags&kAudioTimeStampHostTimeValid)||!in->mNumberBuffers)return noErr;
        uint32_t frames=UINT32_MAX,totalChannels=0;
        for(UInt32 b=0;b<in->mNumberBuffers;b++) {
            auto &buffer=in->mBuffers[b];if(!buffer.mNumberChannels||!buffer.mData)return noErr;
            frames=std::min(frames,buffer.mDataByteSize/(buffer.mNumberChannels*(UInt32)sizeof(float)));
            totalChannels+=buffer.mNumberChannels;
        }
        if(totalChannels>4||!totalChannels||frames==UINT32_MAX)return noErr;
        double scalar=(time->mFlags&kAudioTimeStampRateScalarValid)?time->mRateScalar:1.0;
        if(!std::isfinite(scalar)||scalar<0.95||scalar>1.05)scalar=1;
        for(uint32_t offset=0;offset<frames;offset+=DJI_MAX_PACKET_FRAMES) {
            auto w=self.write.load(std::memory_order_relaxed);
            if(w-self.read.load(std::memory_order_acquire)>=QueueSize){self.dropped++;continue;}
            auto& packet=self.queue[w%QueueSize];packet.version=1;packet.frames=std::min((uint32_t)DJI_MAX_PACKET_FRAMES,frames-offset);
            packet.channels=DJI_CHANNELS;packet.reserved=0;
            packet.hostTime=time->mHostTime+(uint64_t)(offset*self.frequency/(self.format.mSampleRate*scalar));
            packet.sourceRate=self.format.mSampleRate;packet.rateScalar=scalar;
            memset(packet.samples,0,packet.frames*DJI_CHANNELS*sizeof(float));
            uint32_t base=0;
            for(UInt32 b=0;b<in->mNumberBuffers;b++) {
                auto &buffer=in->mBuffers[b];auto *values=(const float*)buffer.mData;
                for(uint32_t f=0;f<packet.frames;f++)for(uint32_t c=0;c<buffer.mNumberChannels;c++)
                    packet.samples[f*DJI_CHANNELS+base+c]=values[(offset+f)*buffer.mNumberChannels+c];
                base+=buffer.mNumberChannels;
            }
            self.received+=packet.frames;self.write.store(w+1,std::memory_order_release);
        }
        return noErr;
    }
    void start() {
        reset(target);
        check(AudioDeviceCreateIOProcID(source,capture,this,&proc),"create input callback");
        auto a=addr(kAudioDevicePropertyStreamFormat,kAudioObjectPropertyScopeInput);
        AudioObjectAddPropertyListener(source,&a,changed,nullptr);
        check(AudioDeviceStart(source,proc),"start receiver");started=true;lastCallback=mach_absolute_time();
    }
    void drain() {
        auto a=addr(DJI_PACKET_SELECTOR);
        while(read.load(std::memory_order_relaxed)<write.load(std::memory_order_acquire)) {
            auto r=read.load(std::memory_order_relaxed);auto &p=queue[r%QueueSize];
            auto bytes=(UInt32)(offsetof(DJIPacket,samples)+p.frames*DJI_CHANNELS*sizeof(float));
            CFDataRef payload=CFDataCreate(NULL,(const UInt8*)&p,bytes);
            lastError=AudioObjectSetPropertyData(target,&a,0,nullptr,sizeof(payload),&payload);CFRelease(payload);
            if(lastError)Dirty=true;else sent+=p.frames;
            read.store(r+1,std::memory_order_release);
        }
    }
    bool healthy() const {return lastError==noErr&&(mach_absolute_time()-lastCallback.load())<frequency*2;}
    ~Session() {
        if(started)AudioDeviceStop(source,proc);
        if(proc)AudioDeviceDestroyIOProcID(source,proc);
        auto a=addr(kAudioDevicePropertyStreamFormat,kAudioObjectPropertyScopeInput);
        AudioObjectRemovePropertyListener(source,&a,changed,nullptr);
        reset(target);
    }
};
static std::vector<Config> loadConfig(NSString *path) {
    if(![[NSFileManager defaultManager] fileExistsAtPath:path])return {};
    NSData *data=[NSData dataWithContentsOfFile:path];NSError *error=nil;
    id json=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:&error]:nil;
    if(![json isKindOfClass:[NSArray class]]||[json count]>2)throw std::runtime_error("設定ファイルの登録数は最大2台です");
    std::vector<Config> configs;std::set<uint32_t> ports;std::set<std::string> uids;
    for(id row in json) {
        if(![row isKindOfClass:[NSDictionary class]])throw std::runtime_error("設定の形式が不正です");
        NSString *location=row[@"usb_location"],*uid=row[@"virtual_uid"];
        if(![location isKindOfClass:[NSString class]]||![uid isKindOfClass:[NSString class]])throw std::runtime_error("usb_location と virtual_uid が必要です");
        NSScanner *scanner=[NSScanner scannerWithString:location];unsigned long long value=0;
        if(![scanner scanHexLongLong:&value]||!scanner.isAtEnd||!value||value>UINT32_MAX)throw std::runtime_error("USB location が不正です");
        std::string u=uid.UTF8String;
        if((u!=DJI_UID_A&&u!=DJI_UID_B)||!ports.insert((uint32_t)value).second||!uids.insert(u).second)throw std::runtime_error("USB location と仮想 UID は一意にしてください");
        configs.push_back({(uint32_t)value,u,u==DJI_UID_A?"DJI Mic3 RX A":"DJI Mic3 RX B"});
    }
    return configs;
}
static void printList() {
    auto usb=usbDevices();auto physical=audioDevices(true);auto resolved=dji::resolve(usb,physical);
    NSMutableArray *rows=[NSMutableArray array];
    for(auto &u:usb) {
        auto found=resolved.find(u.location);
        [rows addObject:@{@"usb_location":[NSString stringWithFormat:@"0x%08x",u.location],@"usb_serial":@(u.serial.c_str()),
            @"audio_id":@(found==resolved.end()?0:found->second.id),@"audio_uid":@(found==resolved.end()?"":found->second.uid.c_str())}];
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes,1,data.length,stdout);putchar('\n');
}
int main(int argc,const char *argv[]) {@autoreleasepool {
    try {
        if(argc==2&&std::string(argv[1])=="--list"){printList();return 0;}
        std::vector<std::string> defaultArgs;
        if(argc==1) {
            NSString *userConfig=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DJI Mic Bridge/receivers.json"];
            NSString *path=userConfig;
            defaultArgs={argv[0],"--config",path.UTF8String};
        }
        std::vector<const char*> args;
        if(!defaultArgs.empty()){for(auto& arg:defaultArgs)args.push_back(arg.c_str());argc=(int)args.size();argv=args.data();}
        if(argc<3||std::string(argv[1])!="--config")throw std::runtime_error("使用法: dji-mic-bridge --list | --config PATH [--seconds N] [--no-driver]");
        auto configs=loadConfig(@(argv[2]));double seconds=0;bool noDriver=false;
        for(int i=3;i<argc;i++) {
            std::string arg=argv[i];
            if(arg=="--no-driver")noDriver=true;
            else if(arg=="--seconds"&&i+1<argc){seconds=std::stod(argv[++i]);if(!std::isfinite(seconds)||seconds<=0)throw std::runtime_error("seconds は正の有限値が必要です");}
            else throw std::runtime_error("不明な引数: "+arg);
        }
        NSString *lockPath=[NSTemporaryDirectory() stringByAppendingPathComponent:@"local.dji-mic.bridge.lock"];
        int lockFD=open(lockPath.fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
        if(lockFD<0||flock(lockFD,LOCK_EX|LOCK_NB))throw std::runtime_error("ブリッジはすでに起動しているか、ロックを取得できません");
        if(!noDriver) {
            auto auth=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
            if(auth==AVAuthorizationStatusNotDetermined){dispatch_semaphore_t sem=dispatch_semaphore_create(0);__block bool granted=false;
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok){granted=ok;dispatch_semaphore_signal(sem);}];
                if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))||!granted)throw std::runtime_error("マイク権限が必要です");
            }else if(auth!=AVAuthorizationStatusAuthorized)throw std::runtime_error("マイク権限が必要です");
        }
        signal(SIGINT,signalStop);signal(SIGTERM,signalStop);
        auto a=addr(kAudioHardwarePropertyDevices);check(AudioObjectAddPropertyListener(kAudioObjectSystemObject,&a,changed,nullptr),"device listener");
        std::array<std::unique_ptr<Session>,2> sessions;std::array<std::string,2> previous;
        auto begin=std::chrono::steady_clock::now(),lastScan=begin-std::chrono::seconds(1);
        while(Running) {@autoreleasepool {
            auto now=std::chrono::steady_clock::now();
            if(seconds>0&&std::chrono::duration<double>(now-begin).count()>=seconds)break;
            if(Dirty.exchange(false)||now-lastScan>=std::chrono::milliseconds(500)) {
                lastScan=now;
                auto physical=audioDevices(true),all=audioDevices(false);auto mapped=dji::resolve(usbDevices(),physical);
                for(unsigned i=0;i<configs.size();i++) {
                    auto &config=configs[i];auto found=mapped.find(config.location);AudioObjectID target=0;
                    for(auto &d:all)if(d.uid==config.uid)target=d.id;
                    AudioObjectID source=found==mapped.end()?0:found->second.id;
                    if(sessions[i]&&(!source||!target||sessions[i]->source!=source||sessions[i]->target!=target||!sessions[i]->healthy()))sessions[i].reset();
                    // フォーマット変更を検出した場合も入力を作り直す。
                    if(sessions[i]){AudioStreamBasicDescription format{};auto p=addr(kAudioDevicePropertyStreamFormat,kAudioObjectPropertyScopeInput);UInt32 bytes=sizeof(format);
                        if(AudioObjectGetPropertyData(source,&p,0,nullptr,&bytes,&format)||memcmp(&format,&sessions[i]->format,sizeof(format)))sessions[i].reset();}
                    std::string status=noDriver?"監視のみ":!target?"ドライバー未導入":!source?"レシーバー未接続":"接続中";
                    if(!noDriver&&source&&target&&!sessions[i]) {
                        try{sessions[i]=std::make_unique<Session>(source,target);sessions[i]->start();}
                        catch(const std::exception& e){sessions[i].reset();status=std::string("再試行待ち: ")+e.what();}
                    }
                    status+=" source="+std::to_string(source)+" target="+std::to_string(target);
                    if(status!=previous[i]){std::cerr<<config.name<<": "<<status<<std::endl;previous[i]=status;}
                }
            }
            for(auto &s:sessions)if(s)s->drain();
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
        }}
        for(unsigned i=0;i<sessions.size();i++)if(sessions[i])std::cerr<<configs[i].name<<": received="<<sessions[i]->received<<" sent="<<sessions[i]->sent<<" dropped="<<sessions[i]->dropped<<std::endl;
        sessions={};AudioObjectRemovePropertyListener(kAudioObjectSystemObject,&a,changed,nullptr);close(lockFD);return 0;
    }catch(const std::exception& error){std::cerr<<"エラー: "<<error.what()<<std::endl;return 1;}
}}
