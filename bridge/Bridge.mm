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
#include "Waveform.hpp"
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
    dji::Waveform waveform;
    std::unique_ptr<dji::Recorder> recorder;
    std::string recordingPath,recordingError;
    uint64_t recordedFrames=0;
    void stopRecording(){if(recorder){waveform.flush();recordedFrames=recorder->frames;auto error=recorder->close();if(error)recordingError="録音の終了処理エラー: "+std::to_string(error);recorder.reset();}}
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
            if(recorder){try{recorder->append(p.samples,p.frames);recordedFrames=recorder->frames;waveform.append(p.samples,p.frames,p.hostTime/frequency,format.mSampleRate*p.rateScalar);}catch(const std::exception& e){recordingError=e.what();stopRecording();}}

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
    std::string serial,name,firmware,status="未接続",error,path,previous,controlMessage;
    bool inUse=false,controlBusy=false;
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
    std::string globalError,commandError;
    unsigned unidentified=0;
    unsigned busChannels=16;
    NSMutableArray *routes=[NSMutableArray array];
    NSString *routingPath;
    NSString *labelsPath;NSMutableDictionary *labels=[NSMutableDictionary dictionary];
    bool busInUse=false;
    std::set<AudioObjectID> runningListeners;
    struct ControlJob {NSTask *task;NSPipe *output;std::string serial;bool started=false;};
    std::vector<ControlJob> controlJobs;
    void pollControls(){
        if(controlJobs.empty())return;auto& job=controlJobs.front();auto r=receivers.find(job.serial);
        if(!job.started){NSError *error=nil;if([job.task launchAndReturnError:&error]){job.started=true;return;}
            if(r!=receivers.end())r->second.error=error.localizedDescription.UTF8String;controlJobs.erase(controlJobs.begin());if(r!=receivers.end())r->second.controlBusy=std::any_of(controlJobs.begin(),controlJobs.end(),[&](auto& pending){return pending.serial==r->first;});return;}
        if(job.task.running)return;
        NSData *data=[job.output.fileHandleForReading readDataToEndOfFile];id result=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(r!=receivers.end()){r->second.controlBusy=false;bool ok=job.task.terminationStatus==0&&[result isKindOfClass:[NSDictionary class]]&&[result[@"success"] boolValue];
            NSString *message=[result isKindOfClass:[NSDictionary class]]&&[result[@"message"] isKindOfClass:[NSString class]]?result[@"message"]:@"機器の応答を確認できませんでした。";
            r->second.controlMessage=message.UTF8String;if(!ok)r->second.error=message.UTF8String;
            if([result isKindOfClass:NSDictionary.class])recordControlChange(r->second,job.task.arguments,result);
            identities.refresh(job.serial);}
        controlJobs.erase(controlJobs.begin());
        if(r!=receivers.end())r->second.controlBusy=std::any_of(controlJobs.begin(),controlJobs.end(),[&](auto& pending){return pending.serial==r->first;});
    }
    void recordControlChange(Receiver& r,NSArray *arguments,NSDictionary *result){
        if(!r.session||!r.session->recorder)return;
        auto& session=*r.session;session.drain();
        NSString *path=[ns(session.recordingPath) stringByAppendingString:@".json"];NSError *error=nil;
        NSData *original=[NSData dataWithContentsOfFile:path];
        id raw=original?[NSJSONSerialization JSONObjectWithData:original options:NSJSONReadingMutableContainers error:&error]:nil;
        if(![raw isKindOfClass:NSMutableDictionary.class]){r.error="録音は継続中ですが、設定変更履歴を保存できませんでした。";return;}
        NSMutableArray *events=raw[@"control_events"];
        if(![events isKindOfClass:NSMutableArray.class]){events=[NSMutableArray array];raw[@"control_events"]=events;}
        [events addObject:@{@"host_seconds":@(mach_absolute_time()/hostFrequency()),@"recorded_frame":@(session.recordedFrames),
            @"command":arguments,@"success":result[@"success"]?:@NO,@"message":result[@"message"]?:@"",@"status":result[@"status"]?:@{}}];
        NSData *data=[NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingPrettyPrinted error:&error];
        if(!data||![data writeToFile:path options:NSDataWritingAtomic error:&error])r.error="録音は継続中ですが、設定変更履歴を保存できませんでした。";
    }
    void enqueue(Receiver& r,NSArray *arguments,bool priorityStop=false){if(!r.location||(r.controlBusy&&!priorityStop))throw std::runtime_error("接続を確認するか、前の機器操作の完了を待ってください。");
        NSTask *task=[NSTask new];NSPipe *output=[NSPipe pipe];task.standardOutput=output;task.standardError=[NSFileHandle fileHandleWithNullDevice];
        task.executableURL=[NSURL fileURLWithPath:[[[NSBundle mainBundle].executablePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"dji-mic-control"]];task.arguments=arguments;
        r.controlBusy=true;r.controlMessage=priorityStop?"停止待ち":"適用待ち";
        if(priorityStop){for(auto it=controlJobs.begin();it!=controlJobs.end();)if(it->serial==r.serial&&!it->started)it=controlJobs.erase(it);else++it;
            auto position=controlJobs.begin();if(position!=controlJobs.end()&&position->started)++position;controlJobs.insert(position,{task,output,r.serial,false});}
        else controlJobs.push_back({task,output,r.serial,false});
    }
    std::string labelKey(const Receiver& r,unsigned index,const dji::TransmitterState *tx=nullptr){auto slot=r.serial+":TX"+std::to_string(index);NSString *mapping=labels[ns("@slot:"+slot)];
        if(tx&&!tx->serial.empty())return tx->serial;
        return [mapping isKindOfClass:[NSString class]]&&dji::validSerial(mapping.UTF8String)?std::string(mapping.UTF8String):slot;}
    void rememberTransmitters(const Receiver& r,const dji::Telemetry& state){bool changed=false;
        for(auto& [index,tx]:state.transmitters){if(tx.serial.empty())continue;auto slot=r.serial+":TX"+std::to_string(index);NSString *key=ns("@slot:"+slot);
            if(![labels[key] isEqual:ns(tx.serial)]){labels[key]=ns(tx.serial);if(!labels[ns(tx.serial)]&&labels[ns(slot)])labels[ns(tx.serial)]=labels[ns(slot)];changed=true;}}
        if(changed)try{saveLabels();}catch(const std::exception& e){commandError=e.what();}}

    void saveLabels(){NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:labels options:NSJSONWritingPrettyPrinted error:&error];if(!data||![data writeToFile:labelsPath options:NSDataWritingAtomic error:&error])throw std::runtime_error(error.localizedDescription.UTF8String);}

    void recordLabelChange(NSArray *changes){
        // microphonesを保持し、変更をlabel_eventsへ追記する。
        for(auto& [serial,r]:receivers)if(r.session&&r.session->recorder){auto& session=*r.session;session.drain();
            NSString *path=[ns(session.recordingPath) stringByAppendingString:@".json"];NSError *error=nil;
            NSData *original=[NSData dataWithContentsOfFile:path];id raw=original?[NSJSONSerialization JSONObjectWithData:original options:NSJSONReadingMutableContainers error:&error]:nil;
            if(![raw isKindOfClass:NSMutableDictionary.class]){r.error="録音は継続中ですが、人物アサインの履歴を保存できませんでした。";continue;}
            NSMutableArray *events=raw[@"label_events"];if(![events isKindOfClass:NSMutableArray.class]){events=[NSMutableArray array];raw[@"label_events"]=events;}
            auto tc=identities.status(serial);
            [events addObject:@{@"host_seconds":@(mach_absolute_time()/hostFrequency()),@"recorded_frame":@(session.recordedFrames),@"timecode":ns(tc.timecode),@"tc_observed_host_seconds":@(tc.observedHostSeconds),@"changes":changes}];
            NSData *data=[NSJSONSerialization dataWithJSONObject:raw options:NSJSONWritingPrettyPrinted error:&error];
            if(!data||![data writeToFile:path options:NSDataWritingAtomic error:&error])r.error="録音は継続中ですが、人物アサインの履歴を保存できませんでした。";
        }
    }

    void saveRouting(){NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"channels":@(busChannels),@"routes":routes} options:NSJSONWritingPrettyPrinted error:&error];
        if(!data||![data writeToFile:routingPath options:NSDataWritingAtomic error:&error])throw std::runtime_error(error.localizedDescription.UTF8String);}
    NSMutableArray *driverRows(){NSMutableArray *rows=[NSMutableArray array];for(auto& [serial,r]:receivers)[rows addObject:@{@"uid":ns(r.uid()),@"name":ns(r.name)}];
        NSMutableArray *mapped=[NSMutableArray array];for(unsigned i=0;i<busChannels;i++){id r=routes[i];if(r==NSNull.null){[mapped addObject:@{}];continue;}
            [mapped addObject:@{@"uid":[@"local.dji-mic.input." stringByAppendingString:r[@"serial"]],@"channel":@([r[@"channel"] unsignedIntValue]-1)}];}
        [rows addObject:@{@"uid":@DJI_BUS_UID,@"name":@"DJI Mic3 Matrix",@"channels":@(busChannels),@"routes":mapped}];return rows;}
    void updateBusUse(){busInUse=false;for(auto& d:audioDevices(false))if(d.uid==DJI_BUS_UID){auto a=addr(kAudioDevicePropertyDeviceIsRunningSomewhere);UInt32 value=0,size=sizeof(value);busInUse=AudioObjectGetPropertyData(d.id,&a,0,nullptr,&size,&value)!=noErr||value!=0;}}
    void routingCommand(NSDictionary *command){commandError.clear();try{
        NSString *op=command[@"op"];
        if([op isEqual:@"bus_channels"]){unsigned requested=[command[@"channels"] intValue];if(requested<4||requested>64||requested%4)throw std::runtime_error("チャンネル数は4〜64の4の倍数を指定してください。");
            if(requested==busChannels)return;updateBusUse();if(busInUse)throw std::runtime_error("DAW が共通入力を使用中です。入力の使用を終了してからチャンネル数を変更してください。");
            auto a=addr(DJI_REMOVE_SELECTOR);CFStringRef uid=CFSTR(DJI_BUS_UID);check(AudioObjectSetPropertyData(plugin(),&a,0,nullptr,sizeof(uid),&uid),"共通入力の変更");
            unsigned old=busChannels;busChannels=requested;try{saveRouting();}catch(...){busChannels=old;configDirty=true;throw;}configDirty=true;Dirty=true;
        }else if([op isEqual:@"route"]){int destination=[command[@"destination"] intValue],channel=[command[@"channel"] intValue];NSString *serial=command[@"source_serial"];
            if(destination<1||(unsigned)destination>busChannels||channel<1||channel>4||![serial isKindOfClass:[NSString class]]|| (serial.length&&!dji::validSerial(serial.UTF8String)))throw std::runtime_error("マトリクスの指定が不正です。");
            id old=routes[destination-1];routes[destination-1]=serial.length?@{@"serial":serial,@"channel":@(channel)}:NSNull.null;
            try{saveRouting();}catch(...){routes[destination-1]=old;throw;}configDirty=true;Dirty=true;
        }
    }catch(const std::exception& e){commandError=e.what();}}

    AudioObjectID lastPlugin=0;
public:
    Manager(NSString *path):configPath(path){
        routingPath=[[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"routing.json"];
        labelsPath=[[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"labels.json"];
        if([[NSFileManager defaultManager] fileExistsAtPath:labelsPath]){id saved=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:labelsPath] options:0 error:nil];
            if(![saved isKindOfClass:[NSDictionary class]])throw std::runtime_error("labels.json の形式が不正です。元ファイルを保護して終了します。");
            for(id key in saved)if(![key isKindOfClass:[NSString class]]||![saved[key] isKindOfClass:[NSString class]])throw std::runtime_error("labels.json のラベルが不正です。");labels=[saved mutableCopy];}

        for(unsigned i=0;i<64;i++)[routes addObject:NSNull.null];
        if([[NSFileManager defaultManager] fileExistsAtPath:routingPath]){NSData *data=[NSData dataWithContentsOfFile:routingPath];id config=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            if(![config isKindOfClass:[NSDictionary class]]||![config[@"channels"] isKindOfClass:[NSNumber class]])throw std::runtime_error("routing.json の形式が不正です。");
            unsigned count=[config[@"channels"] unsignedIntValue];id saved=config[@"routes"];
            if(count<4||count>64||count%4||![saved isKindOfClass:[NSArray class]]||[saved count]!=64)throw std::runtime_error("routing.json が不正です。元ファイルを保護して終了します。");
            for(id row in saved)if(row!=NSNull.null&&(![row isKindOfClass:[NSDictionary class]]||![row[@"serial"] isKindOfClass:[NSString class]]||!dji::validSerial([row[@"serial"] UTF8String])||![row[@"channel"] isKindOfClass:[NSNumber class]]||[row[@"channel"] intValue]<1||[row[@"channel"] intValue]>4))throw std::runtime_error("routing.json の割り当てが不正です。");
            busChannels=count;routes=[saved mutableCopy];
        }

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
            if(!receivers.count(identity.serial)){auto& r=receivers[identity.serial];r.serial=identity.serial;r.name="DJI Mic3 · "+r.serial;configDirty=true;save();
                bool assigned=false;for(id route in routes)if(route!=NSNull.null&&[route[@"serial"] isEqual:ns(r.serial)])assigned=true;
                if(!assigned)for(unsigned base=0;base<busChannels;base+=4){bool free=true;for(unsigned c=0;c<4;c++)if(routes[base+c]!=NSNull.null)free=false;
                    if(free){for(unsigned c=0;c<4;c++)routes[base+c]=@{@"serial":ns(r.serial),@"channel":@(c+1)};break;}}
                saveRouting();}
            receivers[identity.serial].firmware=identity.firmware;
        }
        if(![[NSFileManager defaultManager] fileExistsAtPath:routingPath]){
            unsigned ch=0;for(auto& [serial,r]:receivers){for(unsigned source=1;source<=4&&ch<64;source++,ch++)routes[ch]=@{@"serial":ns(serial),@"channel":@(source)};}save();saveRouting();
        }
        auto plug=plugin();if(plug!=lastPlugin){configDirty=true;lastPlugin=plug;}
        globalError=plug?"":"専用 HAL ドライバーが見つかりません。Install.command を実行してください。";
        if(plug&&configDirty){NSMutableArray *rows=driverRows();
            auto a=addr(DJI_DEVICES_SELECTOR);CFArrayRef value=(__bridge CFArrayRef)rows;
            auto error=AudioObjectSetPropertyData(plug,&a,0,nullptr,sizeof(value),&value);
            if(error)globalError="仮想入力の登録に失敗: "+std::to_string(error);else configDirty=false;
        }
        auto all=audioDevices(false);
        for(auto& d:all)if(d.uid.find("local.dji-mic.input.")==0&&!runningListeners.count(d.id)){auto a=addr(kAudioDevicePropertyDeviceIsRunningSomewhere);if(!AudioObjectAddPropertyListener(d.id,&a,changed,nullptr))runningListeners.insert(d.id);}
        updateBusUse();
        for(auto& [serial,r]:receivers){AudioObjectID source=0,target=0;r.location=0;
            auto seen=found.find(serial);bool duplicate=seen!=found.end()&&seen->second.size()>1;
            if(seen!=found.end()&&!duplicate){r.location=seen->second[0];auto sourceIt=mapping.find(r.location);if(sourceIt!=mapping.end())source=sourceIt->second.id;}
            for(auto& d:all)if(d.uid==r.uid())target=d.id;
            r.inUse=false;
            if(target){auto runningProperty=addr(kAudioDevicePropertyDeviceIsRunningSomewhere);UInt32 running=0,size=sizeof(running);r.inUse=AudioObjectGetPropertyData(target,&runningProperty,0,nullptr,&size,&running)!=noErr||running!=0;}
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
        if(![command isKindOfClass:[NSDictionary class]])return;
        if([command[@"op"] isEqual:@"bus_channels"]||[command[@"op"] isEqual:@"route"]){routingCommand(command);return;}
        NSString *bulkOp=command[@"op"];
        if([@[@"record_all",@"stop_all",@"device_record_all",@"device_stop_all",@"tc_all",@"refresh_all",@"audio_all"] containsObject:bulkOp]){
            NSString *single=[bulkOp isEqual:@"audio_all"]?@"audio":[bulkOp isEqual:@"record_all"]?@"record":[bulkOp isEqual:@"stop_all"]?@"stop":[bulkOp isEqual:@"tc_all"]?@"tc":[bulkOp isEqual:@"refresh_all"]?@"refresh_controls":@"device_record";
            NSString *selection=command[@"serials"];NSArray *selected=[selection isKindOfClass:[NSString class]]?[selection componentsSeparatedByString:@","]:nil;
            NSMutableDictionary *values=[command mutableCopy];values[@"op"]=single;
            if([bulkOp hasPrefix:@"device_"])values[@"enabled"]=[bulkOp isEqual:@"device_record_all"]?@"1":@"0";
            // 操作開始時に接続対象を確定する。
            for(auto& [serial,r]:receivers){if(selected&&![selected containsObject:ns(serial)])continue;if(!r.session&&![single isEqual:@"stop"])continue;
                if([single isEqual:@"record"]&&r.session&&r.session->recorder)continue;
                if([single isEqual:@"device_record"]){auto status=identities.status(serial);if(status.known&&status.transmitters.empty()){r.error.clear();r.controlMessage="本体録音: 接続中の送信機なし・スキップ";continue;}}
                values[@"serial"]=ns(serial);this->command(values);}
            return;
        }
        if(![command[@"serial"] isKindOfClass:[NSString class]])return;
        auto it=receivers.find([command[@"serial"] UTF8String]);if(it==receivers.end())return;auto& r=it->second;
        r.error.clear();
        try{NSString *op=command[@"op"];
            if([op isEqual:@"rename"]){NSString *name=command[@"name"];
                if(![name isKindOfClass:[NSString class]])return;name=[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if(!name.length||name.length>90||[name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location!=NSNotFound)throw std::runtime_error("名前は 1〜90 文字で、改行を含めず入力してください。");
                for(auto& [serial,other]:receivers)if(serial!=r.serial&&other.name==name.UTF8String)throw std::runtime_error("他のレシーバーと異なる名前にしてください。");
                auto old=r.name;r.name=name.UTF8String;try{save();}catch(...){r.name=old;throw;}configDirty=true;Dirty=true;
            }else if([op isEqual:@"refresh_controls"]){identities.refresh(r.serial);
            }else if([op isEqual:@"label"]){
                NSString *label=command[@"label"],*key=command[@"label_key"];
                if(![key isKindOfClass:[NSString class]]||![label isKindOfClass:[NSString class]]||label.length>80||[label rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location!=NSNotFound)throw std::runtime_error("人物ラベルは80文字以内で入力してください。");
                auto state=identities.status(r.serial);bool allowed=false;for(unsigned index=1;index<=4;index++){auto tx=state.transmitters.find(index);if([key isEqual:ns(labelKey(r,index,tx==state.transmitters.end()?nullptr:&tx->second))])allowed=true;}
                if(!allowed)throw std::runtime_error("マイクの識別情報を更新してからラベルを保存してください。");
                NSString *take=command[@"take_from"];if(take&&(![take isKindOfClass:NSString.class]||[take isEqual:key]||[take hasPrefix:@"@slot:"]))throw std::runtime_error("引き継ぎ元の指定が不正です。");
                if(take){bool found=false;for(auto& [serial,other]:receivers){auto telemetry=identities.status(serial);for(unsigned i=1;i<=4;i++){auto tx=telemetry.transmitters.find(i);if([take isEqual:ns(labelKey(other,i,tx==telemetry.transmitters.end()?nullptr:&tx->second))])found=true;}}
                    if(!found||![labels[take] length])throw std::runtime_error("引き継ぎ元のラベルが変更されました。選び直してください。");}
                NSMutableDictionary *before=[labels mutableCopy];NSString *old=labels[key]?:@"";
                labels[key]=take?labels[take]:[label stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(take)labels[take]=old;
                try{saveLabels();}catch(...){labels=before;throw;}
                NSMutableArray *changes=[NSMutableArray arrayWithObject:@{@"label_key":key,@"before":old,@"after":labels[key]}];
                if(take)[changes addObject:@{@"label_key":take,@"before":before[take]?:@"",@"after":labels[take]}];
                recordLabelChange(changes);
            }else if([op isEqual:@"gain"]||[op isEqual:@"agc"]){
                NSString *target=command[@"target"],*txSerial=command[@"tx_serial"],*value=command[[op isEqual:@"gain"]?@"value":@"mode"];
                if(![target isKindOfClass:NSString.class]||![txSerial isKindOfClass:NSString.class]||![value isKindOfClass:NSString.class])throw std::runtime_error("送信機と設定値が必要です。");
                enqueue(r,@[[op isEqual:@"gain"]?@"--gain":@"--agc",ns(r.serial),target,txSerial,value]);
            }else if([op isEqual:@"lossless"]){NSString *value=command[@"enabled"];if(![value isKindOfClass:NSString.class])throw std::runtime_error("ロスレス設定が必要です。");enqueue(r,@[@"--lossless",ns(r.serial),value]);
            }else if([op isEqual:@"audio"]){
                NSString *quality=command[@"lossless"]?:@"-1",*agc=command[@"agc"]?:@"-1",*noise=command[@"noise"]?:@"keep";
                if(![quality isKindOfClass:NSString.class]||![agc isKindOfClass:NSString.class]||![noise isKindOfClass:NSString.class])throw std::runtime_error("音声設定が不正です。");
                enqueue(r,@[@"--profile",ns(r.serial),quality,agc,noise]);
            }else if([op isEqual:@"tc"]){
                auto valid=[](id value,int maximum){if(![value isKindOfClass:[NSString class]])return false;NSString *v=value;return v.length==1&&[v characterAtIndex:0]>='0'&&[v characterAtIndex:0]<='0'+maximum;};
                if(!valid(command[@"enabled"],1)||!valid(command[@"fps"],7)||!valid(command[@"output"],3))throw std::runtime_error("TC 設定が不正です。");
                enqueue(r,@[@"--tc",ns(r.serial),command[@"enabled"],command[@"fps"],command[@"output"]]);
            }else if([op isEqual:@"device_record"]){
                NSString *enabled=command[@"enabled"];if(![enabled isKindOfClass:[NSString class]]||(![enabled isEqual:@"0"]&&![enabled isEqual:@"1"]))throw std::runtime_error("録音操作が不正です。");
                enqueue(r,@[@"--record",ns(r.serial),enabled],[enabled isEqual:@"0"]);
            }else if([op isEqual:@"noise"]){
                NSString *mode=command[@"mode"];unsigned target=[command[@"target"] intValue];auto states=identities.controls(r.serial);
                if(![mode isKindOfClass:[NSString class]]||(![mode isEqual:@"none"]&&![mode isEqual:@"basic"]&&![mode isEqual:@"strong"])||!states.count(target))throw std::runtime_error("送信機の状態を更新してから操作してください。");
                enqueue(r,@[@"--set",ns(r.serial),[NSString stringWithFormat:@"%u",target],mode]);
            }else if([op isEqual:@"delete"]){
                if(r.session||r.location)throw std::runtime_error("レシーバーを USB から抜いてから登録を削除してください。");
                if(r.inUse)throw std::runtime_error("他のソフトがこの入力を使用中です。USB を抜いても入力と4chの無音を維持します。使用を終了してから削除してください。");
                // 設定だけ消して HAL storage に孤立した入力を残さない。
                AudioObjectID plug=plugin();if(!plug)throw std::runtime_error("登録解除には専用ドライバーが必要です。");
                auto a=addr(DJI_REMOVE_SELECTOR);CFStringRef value=(__bridge CFStringRef)ns(r.uid());
                check(AudioObjectSetPropertyData(plug,&a,0,nullptr,sizeof(value),&value),"仮想入力の登録解除");
                auto node=receivers.extract(it);try{save();}catch(...){receivers.insert(std::move(node));configDirty=true;throw;}
                configDirty=true;Dirty=true;return;
            }else if([op isEqual:@"record"]){
                if(!r.session)throw std::runtime_error("接続中のレシーバーで録音してください。");if(r.session->recorder)return;
                NSString *folder=command[@"folder"];if(![folder isKindOfClass:[NSString class]]||!folder.isAbsolutePath)throw std::runtime_error("保存先フォルダーが必要です。");
                NSError *error=nil;if(![[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error])throw std::runtime_error(error.localizedDescription.UTF8String);
                NSDateFormatter *date=[NSDateFormatter new];date.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];date.dateFormat=@"yyyyMMdd-HHmmss";
                NSString *file=[NSString stringWithFormat:@"%@-%@-%@.caf",[date stringFromDate:NSDate.date],ns(r.serial),NSUUID.UUID.UUIDString];
                r.session->record([[folder stringByAppendingPathComponent:file] fileSystemRepresentation]);
                NSMutableArray *microphones=[NSMutableArray array];auto state=identities.status(r.serial);for(unsigned i=1;i<=4;i++){auto t=state.transmitters.find(i);auto key=labelKey(r,i,t==state.transmitters.end()?nullptr:&t->second);[microphones addObject:@{@"channel":@(i),@"label_key":ns(key),@"label":labels[ns(key)]?:@""}];}
                NSDictionary *metadata=@{@"tc_at_start":@{@"known":@(state.known),@"enabled":@(state.tcEnabled),@"fps":@(state.fps),@"timecode":ns(state.timecode),@"observed_host_seconds":@(state.observedHostSeconds)},@"record_command_host_seconds":@(mach_absolute_time()/hostFrequency()),@"receiver_serial":ns(r.serial),@"receiver_name":ns(r.name),@"microphones":microphones,@"label_events":@[],@"sample_rate":@(r.session->format.mSampleRate),@"channels":@4,@"note":@"チャンネルと送信機の対応はレシーバーの出力モードに従います。"};
                NSError *metadataError=nil;NSData *json=[NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:&metadataError];
                if(!json||![json writeToFile:[[folder stringByAppendingPathComponent:file] stringByAppendingString:@".json"] options:NSDataWritingAtomic error:&metadataError])r.error="音声の録音中ですが、人物ラベルの記録ファイルを保存できませんでした。";

            }else if([op isEqual:@"stop"]){if(r.session)r.session->stopRecording();}
        }catch(const std::exception& e){r.error=e.what();}
    }
    void snapshot(){pollControls();NSMutableArray *rows=[NSMutableArray array];
        for(auto& [serial,r]:receivers){NSMutableArray *peaks=[NSMutableArray array];Session *s=r.session.get();for(unsigned c=0;c<4;c++){[peaks addObject:@(s?s->peaks[c]:0)];if(s)s->peaks[c]=0;}
            auto frames=s?s->recordedFrames:r.frames;double rate=s?s->format.mSampleRate:r.rate;std::string path=s?s->recordingPath:r.path;
            std::string error=s&&!s->recordingError.empty()?s->recordingError:r.error;
            auto state=r.location?identities.status(serial):dji::Telemetry{};rememberTransmitters(r,state);
            NSMutableArray *transmitters=[NSMutableArray array];for(unsigned index=1;index<=4;index++){
                auto it=state.transmitters.find(index);bool live=it!=state.transmitters.end();const dji::TransmitterState *tx=live?&it->second:nullptr;auto key=labelKey(r,index,tx);NSString *label=labels[ns(key)]?:@"";
                [transmitters addObject:@{@"index":@(index),@"serial":tx?ns(tx->serial):@"",@"label_key":ns(key),@"label":label,@"connected":@(live),@"gain_db":@(tx?tx->gain:-1000),@"agc":@(tx?tx->agc:-1),@"noise_mode":tx?ns(tx->noise):@"unknown",@"battery_code":@(tx?tx->battery:-1),@"charging":@(tx&&tx->charging),@"device_recording":@(tx&&tx->recording),@"storage_total":@(tx?tx->total:-1),@"storage_remaining":@(tx?tx->remaining:-1)}];
            }
            NSMutableArray *wave=[NSMutableArray array];if(s)for(auto& bin:s->waveform.take()){NSMutableArray *low=[NSMutableArray array],*high=[NSMutableArray array];for(unsigned c=0;c<4;c++){[low addObject:@(bin.low[c])];[high addObject:@(bin.high[c])];}[wave addObject:@{@"time":@(bin.time),@"duration":@(bin.duration),@"low":low,@"high":high}];}
            NSDictionary *tc=@{@"observed_host_seconds":@(state.observedHostSeconds),@"known":@(state.known),@"enabled":@(state.tcEnabled),@"fps":@(state.fps),@"output":@(state.output),@"timecode":ns(state.timecode)};
            [rows addObject:@{@"serial":ns(serial),@"name":ns(r.name),@"firmware":ns(r.firmware),@"status":ns(r.status),@"connected":@(s!=nullptr),@"can_delete":@(!s&&!r.location&&!r.inUse),
                @"source_id":@(s?s->source:0),@"virtual_id":@(s?s->target:0),@"virtual_uid":ns(r.uid()),@"usb_location":[NSString stringWithFormat:@"0x%08x",r.location],
                @"gain_db":@(state.gain),@"lossless":@(state.lossless),@"waveform":wave,@"transmitters":transmitters,@"tc":tc,@"control_message":ns(r.controlMessage),@"battery_code":@(state.battery),@"charging":@(state.charging),@"control_busy":@(r.controlBusy),@"meters":peaks,@"recording":@(s&&s->recorder),@"recorded_seconds":@(frames/rate),@"recording_path":ns(path),@"error":ns(error),@"dropped":@(s?s->dropped.load():0)}];
        }
        emit(@{@"host_seconds":@(mach_absolute_time()/hostFrequency()),@"receivers":rows,@"unidentified":@(unidentified),@"error":ns(globalError.empty()?commandError:globalError),@"bus_channels":@(busChannels),@"bus_in_use":@(busInUse),@"routes":routes});
    }
    ~Manager(){for(auto id:runningListeners){auto a=addr(kAudioDevicePropertyDeviceIsRunningSomewhere);AudioObjectRemovePropertyListener(id,&a,changed,nullptr);}for(auto& [serial,r]:receivers)r.disconnect();for(auto& job:controlJobs)if(job.started)[job.task waitUntilExit];}
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
            manager.drain();if(now-snapshot>std::chrono::milliseconds(33)){snapshot=now;manager.snapshot();}
            if(CFRunLoopRunInMode(kCFRunLoopDefaultMode,.003,false)==kCFRunLoopRunFinished)std::this_thread::sleep_for(std::chrono::milliseconds(3));
        }}
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject,&a,changed,nullptr);close(lockFD);return 0;
    }catch(const std::exception& e){emit(@{@"receivers":@[],@"unidentified":@0,@"error":@(e.what())});std::cerr<<e.what()<<std::endl;return 1;}
}}
