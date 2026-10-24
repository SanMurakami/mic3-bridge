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
#include "USBIdentityMonitor.hpp"
#include "Recorder.hpp"
#include <fcntl.h>
#include <cmath>
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
static std::map<uint32_t,uint64_t> RegistryIDs;
static std::vector<dji::USB> usbDevices() {
    RegistryIDs.clear();
    io_iterator_t iterator=0;std::vector<dji::USB> result;
    if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&iterator)!=KERN_SUCCESS)return result;
    io_service_t service;
    while((service=IOIteratorNext(iterator))) {
        CFMutableDictionaryRef props=nullptr;
        if(IORegistryEntryCreateCFProperties(service,&props,kCFAllocatorDefault,0)==KERN_SUCCESS) {
            NSDictionary *dict=CFBridgingRelease(props);
            if([dict[@"idVendor"] unsignedIntValue]==0x2ca3&&[dict[@"USB Product Name"] isEqual:@"Wireless Mic Rx"])
            {uint32_t location=[dict[@"locationID"] unsignedIntValue];uint64_t registry=0;IORegistryEntryGetRegistryEntryID(service,&registry);
                RegistryIDs[location]=registry;result.push_back({location,[(NSString*)dict[@"USB Serial Number"] UTF8String]?:""});}
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

struct Session {
    static constexpr unsigned QueueSize=32;
    AudioObjectID source,target;AudioDeviceIOProcID proc=nullptr;
    AudioStreamBasicDescription format{};
    std::array<DJIPacket,QueueSize> queue{};
    std::atomic<uint64_t> write{0},read{0},dropped{0},lastCallback{0},received{0};
    uint64_t sent=0;OSStatus lastError=0;
    double frequency;
    bool started=false;
    std::array<float,4> peaks{};
    std::unique_ptr<dji::Recorder> recorder;
    std::string recordingPath,recordingError;
    uint64_t recordedFrames=0;
    void stopRecording(){if(recorder){recordedFrames=recorder->frames;auto error=recorder->close();if(error)recordingError="録音の終了処理エラー: "+std::to_string(error);recorder.reset();}}
    void record(const std::string& path){stopRecording();recordingError.clear();recordedFrames=0;recorder=std::make_unique<dji::Recorder>(path,format.mSampleRate);recordingPath=path;}

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
            for(unsigned f=0;f<p.frames;f++)for(unsigned c=0;c<4;c++)if(std::isfinite(p.samples[f*4+c]))peaks[c]=std::max(peaks[c],std::abs(p.samples[f*4+c]));
            if(recorder){try{recorder->append(p.samples,p.frames);recordedFrames=recorder->frames;}catch(const std::exception& e){recordingError=e.what();stopRecording();}}

            read.store(r+1,std::memory_order_release);
        }
    }
    bool healthy() const {return lastError==noErr&&(mach_absolute_time()-lastCallback.load())<frequency*2;}
    ~Session() {
        stopRecording();
        if(started)AudioDeviceStop(source,proc);
        if(proc)AudioDeviceDestroyIOProcID(source,proc);
        auto a=addr(kAudioDevicePropertyStreamFormat,kAudioObjectPropertyScopeInput);
        AudioObjectRemovePropertyListener(source,&a,changed,nullptr);
        reset(target);
    }
};
static NSString *ns(const std::string& value){return @(value.c_str());}
struct Receiver {
    std::string serial,name,firmware,status="未接続",error,path,previous;
    uint32_t location=0;uint64_t frames=0;double rate=48000;
    std::unique_ptr<Session> session;
    std::string uid()const{return "local.dji-mic.input."+serial;}
    void disconnect(){if(session){session->drain();session->stopRecording();path=session->recordingPath;frames=session->recordedFrames;rate=session->format.mSampleRate;
        if(!session->recordingError.empty())error=session->recordingError;session.reset();}}
};
static AudioObjectID plugin() {
    auto a=addr(kAudioHardwarePropertyTranslateBundleIDToPlugIn);CFStringRef bundle=CFSTR("local.dji-mic.inputs.driver");AudioObjectID id=0;UInt32 size=sizeof(id);
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(bundle),&bundle,&size,&id))return 0;return id;
}
static void emit(id object){NSData *data=[NSJSONSerialization dataWithJSONObject:object options:0 error:nil];if(data){fwrite(data.bytes,1,data.length,stdout);putchar('\n');fflush(stdout);}}
class Manager {
    std::map<std::string,Receiver> receivers;
    dji::USBIdentityMonitor identities;
    NSString *configPath;
    bool configDirty=true;
    std::string globalError;
    unsigned unidentified=0;
    AudioObjectID lastPlugin=0;
public:
    Manager(NSString *path):configPath(path){
        if(![[NSFileManager defaultManager] fileExistsAtPath:path])return;
        NSData *data=[NSData dataWithContentsOfFile:path];NSError *error=nil;
        id rows=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:&error]:nil;
        if(![rows isKindOfClass:[NSArray class]])throw std::runtime_error("receivers.json が壊れています。元ファイルを保護して終了します");
        for(id row in rows){if(![row isKindOfClass:[NSDictionary class]]||![row[@"serial"] isKindOfClass:[NSString class]]||![row[@"name"] isKindOfClass:[NSString class]])throw std::runtime_error("receivers.json の形式が不正です");
            std::string serial=[row[@"serial"] UTF8String],name=[row[@"name"] UTF8String];
            if(!dji::validSerial(serial)||!name.size()||[row[@"name"] length]>90||receivers.count(serial))throw std::runtime_error("登録した serial / 名前が不正です");
            auto& r=receivers[serial];r.serial=serial;r.name=name;
        }
    }
    void save(){
        NSMutableArray *rows=[NSMutableArray array];for(auto& [serial,r]:receivers)[rows addObject:@{@"serial":ns(serial),@"name":ns(r.name)}];
        NSError *error=nil;NSString *dir=[configPath stringByDeletingLastPathComponent];
        if(![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error])throw std::runtime_error(error.localizedDescription.UTF8String);
        NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:&error];
        if(!data||![data writeToFile:configPath options:NSDataWritingAtomic error:&error])throw std::runtime_error(error.localizedDescription.UTF8String);
    }
    void scan(){
        auto usb=usbDevices();auto physical=audioDevices(true);auto mapping=dji::resolve(usb,physical);
        std::map<std::string,std::vector<uint32_t>> found;unidentified=0;
        for(auto& u:usb){auto identity=identities.get(RegistryIDs[u.location]);if(identity.serial.empty()){unidentified++;continue;}
            found[identity.serial].push_back(u.location);
            if(!receivers.count(identity.serial)){auto& r=receivers[identity.serial];r.serial=identity.serial;r.name="DJI Mic3 · "+r.serial;configDirty=true;save();}
            receivers[identity.serial].firmware=identity.firmware;
        }
        auto plug=plugin();if(plug!=lastPlugin){configDirty=true;lastPlugin=plug;}
        globalError=plug?"":"専用 HAL ドライバーが見つかりません。Install.command を実行してください。";
        if(plug&&configDirty){NSMutableArray *rows=[NSMutableArray array];for(auto& [serial,r]:receivers)[rows addObject:@{@"uid":ns(r.uid()),@"name":ns(r.name)}];
            auto a=addr(DJI_DEVICES_SELECTOR);CFArrayRef value=(__bridge CFArrayRef)rows;
            auto error=AudioObjectSetPropertyData(plug,&a,0,nullptr,sizeof(value),&value);
            if(error)globalError="仮想入力の登録に失敗: "+std::to_string(error);else configDirty=false;
        }
        auto all=audioDevices(false);
        for(auto& [serial,r]:receivers){AudioObjectID source=0,target=0;r.location=0;
            auto seen=found.find(serial);bool duplicate=seen!=found.end()&&seen->second.size()>1;
            if(seen!=found.end()&&!duplicate){r.location=seen->second[0];auto sourceIt=mapping.find(r.location);if(sourceIt!=mapping.end())source=sourceIt->second.id;}
            for(auto& d:all)if(d.uid==r.uid())target=d.id;
            if(r.session){AudioStreamBasicDescription format{};auto a=addr(kAudioDevicePropertyStreamFormat,kAudioObjectPropertyScopeInput);UInt32 size=sizeof(format);
                bool changedFormat=source&& (AudioObjectGetPropertyData(source,&a,0,nullptr,&size,&format)||memcmp(&format,&r.session->format,sizeof(format)));
                if(r.session->source!=source||r.session->target!=target||!r.session->healthy()||changedFormat){bool recording=!!r.session->recorder;r.disconnect();if(recording)r.error="接続または音声形式の変更により録音を終了しました。";}}
            r.status=duplicate?"個体 ID 重複（転送停止）":!r.location?"未接続":!source?"音声入力を確認中":!target?"仮想入力を準備中":"接続中";
            if(source&&target&&!r.session){try{r.session=std::make_unique<Session>(source,target);r.session->start();}catch(const std::exception& e){r.disconnect();r.status="接続再試行中";r.error=e.what();}}
            std::string state=r.status+" source="+std::to_string(source)+" target="+std::to_string(target)+" location="+std::to_string(r.location);
            if(state!=r.previous){std::cerr<<serial<<": "<<state<<std::endl;r.previous=state;}
        }
    }
    void failed(const std::string& message){globalError=message;for(auto& [serial,r]:receivers){bool recording=r.session&&r.session->recorder;r.disconnect();r.status="音声サービスを再確認中";if(recording)r.error="音声サービスの変更により録音を終了しました。";}}
    void drain(){for(auto& [serial,r]:receivers)if(r.session)r.session->drain();}
    void command(NSDictionary *command){
        if(![command isKindOfClass:[NSDictionary class]]||![command[@"serial"] isKindOfClass:[NSString class]])return;
        auto it=receivers.find([command[@"serial"] UTF8String]);if(it==receivers.end())return;auto& r=it->second;
        r.error.clear();
        try{NSString *op=command[@"op"];
            if([op isEqual:@"rename"]){NSString *name=command[@"name"];
                if(![name isKindOfClass:[NSString class]])return;name=[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if(!name.length||name.length>90||[name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location!=NSNotFound)throw std::runtime_error("名前は 1〜90 文字で、改行を含めず入力してください。");
                for(auto& [serial,other]:receivers)if(serial!=r.serial&&other.name==name.UTF8String)throw std::runtime_error("他のレシーバーと異なる名前にしてください。");
                auto old=r.name;r.name=name.UTF8String;try{save();}catch(...){r.name=old;throw;}configDirty=true;Dirty=true;
            }else if([op isEqual:@"record"]){
                if(!r.session)throw std::runtime_error("接続中のレシーバーで録音してください。");
                NSString *folder=command[@"folder"];if(![folder isKindOfClass:[NSString class]]||!folder.isAbsolutePath)throw std::runtime_error("保存先フォルダーが必要です。");
                NSError *error=nil;if(![[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error])throw std::runtime_error(error.localizedDescription.UTF8String);
                NSDateFormatter *date=[NSDateFormatter new];date.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];date.dateFormat=@"yyyyMMdd-HHmmss";
                NSString *file=[NSString stringWithFormat:@"%@-%@-%@.caf",[date stringFromDate:NSDate.date],ns(r.serial),NSUUID.UUID.UUIDString];
                r.session->record([[folder stringByAppendingPathComponent:file] fileSystemRepresentation]);
            }else if([op isEqual:@"stop"]){if(r.session)r.session->stopRecording();}
        }catch(const std::exception& e){r.error=e.what();}
    }
    void snapshot(){NSMutableArray *rows=[NSMutableArray array];
        for(auto& [serial,r]:receivers){NSMutableArray *peaks=[NSMutableArray array];Session *s=r.session.get();for(unsigned c=0;c<4;c++){[peaks addObject:@(s?s->peaks[c]:0)];if(s)s->peaks[c]=0;}
            auto frames=s?s->recordedFrames:r.frames;double rate=s?s->format.mSampleRate:r.rate;std::string path=s?s->recordingPath:r.path;
            std::string error=s&&!s->recordingError.empty()?s->recordingError:r.error;
            [rows addObject:@{@"serial":ns(serial),@"name":ns(r.name),@"firmware":ns(r.firmware),@"status":ns(r.status),@"connected":@(s!=nullptr),
                @"source_id":@(s?s->source:0),@"virtual_id":@(s?s->target:0),@"virtual_uid":ns(r.uid()),@"usb_location":[NSString stringWithFormat:@"0x%08x",r.location],
                @"meters":peaks,@"recording":@(s&&s->recorder),@"recorded_seconds":@(frames/rate),@"recording_path":ns(path),@"error":ns(error),@"dropped":@(s?s->dropped.load():0)}];
        }
        emit(@{@"receivers":rows,@"unidentified":@(unidentified),@"error":ns(globalError)});
    }
    ~Manager(){for(auto& [serial,r]:receivers)r.disconnect();}
};
int main(int argc,const char *argv[]) {@autoreleasepool{
    try{
        double seconds=0;NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DJI Mic Bridge/receivers.json"];
        for(int i=1;i<argc;i++){std::string arg=argv[i];if(arg=="--seconds"&&i+1<argc)seconds=std::stod(argv[++i]);else if(arg=="--config"&&i+1<argc)path=@(argv[++i]);else throw std::runtime_error("不明な引数: "+arg);}
        int lockFD=open([[NSTemporaryDirectory() stringByAppendingPathComponent:@"local.dji-mic.bridge.lock"] fileSystemRepresentation],O_CREAT|O_RDWR|O_NOFOLLOW,0600);
        if(lockFD<0||flock(lockFD,LOCK_EX|LOCK_NB))throw std::runtime_error("ブリッジがすでに起動しています。");
        signal(SIGINT,signalStop);signal(SIGTERM,signalStop);signal(SIGPIPE,SIG_IGN);
        fcntl(STDIN_FILENO,F_SETFL,fcntl(STDIN_FILENO,F_GETFL)|O_NONBLOCK);
        auto a=addr(kAudioHardwarePropertyDevices);check(AudioObjectAddPropertyListener(kAudioObjectSystemObject,&a,changed,nullptr),"device listener");
        Manager manager(path);std::string pending;pid_t parent=getppid();
        auto begin=std::chrono::steady_clock::now(),scan=begin-std::chrono::seconds(1),snapshot=scan;
        while(Running){@autoreleasepool{
            if(getppid()!=parent)break;
            auto now=std::chrono::steady_clock::now();if(seconds>0&&std::chrono::duration<double>(now-begin).count()>=seconds)break;
            char buffer[4096];ssize_t count=0;while((count=read(STDIN_FILENO,buffer,sizeof(buffer)))>0){pending.append(buffer,count);if(pending.size()>65536){pending.clear();break;}}
            size_t newline;while((newline=pending.find('\n'))!=std::string::npos){auto line=pending.substr(0,newline);pending.erase(0,newline+1);
                NSData *data=[NSData dataWithBytes:line.data() length:line.size()];id command=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];manager.command(command);}
            if(Dirty.exchange(false)||now-scan>std::chrono::milliseconds(500)){scan=now;try{manager.scan();}catch(const std::exception& e){manager.failed(e.what());}}
            manager.drain();if(now-snapshot>std::chrono::milliseconds(200)){snapshot=now;manager.snapshot();}
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
        }}
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject,&a,changed,nullptr);close(lockFD);return 0;
    }catch(const std::exception& e){emit(@{@"receivers":@[],@"unidentified":@0,@"error":@(e.what())});std::cerr<<e.what()<<std::endl;return 1;}
}}
