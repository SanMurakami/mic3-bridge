#pragma once
#include "TimecodeSync.hpp"
#include <memory>
#include <thread>
// 一つのUSB lockと時計を共有し、全RXの準備完了後に時計だけ同時送信する。
struct SyncEndpoint {
    std::string serial;uint64_t registry=0;unsigned previous=0;
    IOUSBHostInterface *iface=nil;IOUSBHostPipe *in=nil,*out=nil;
    dji::IdentityParser parser;dji::TelemetryParser telemetry;
    std::set<uint16_t> acks;uint16_t sequence=uint16_t(arc4random_uniform(65536));
    bool accepted=false,verified=false;double sentHost=0,finishedHost=0,errorFrames=1e9;std::string error;
    NSMutableArray *events=[NSMutableArray array];
    ~SyncEndpoint(){if(iface){if(previous!=1)[iface selectAlternateSetting:previous error:nil];[iface destroy];}}
    static double host(){mach_timebase_info_data_t tb;mach_timebase_info(&tb);return mach_absolute_time()*(double)tb.numer/tb.denom/1e9;}
    void bind(){parser.onFrame=[this](const uint8_t *f,size_t n){auto before=telemetry.state.timecode;bool known=telemetry.state.known;telemetry.frame(f,n);
        if(telemetry.state.known&&(!known||before!=telemetry.state.timecode)){telemetry.state.observedHostSeconds=host();if(sentHost)[events addObject:@{@"tc":@(telemetry.state.timecode.c_str()),@"host":@(telemetry.state.observedHostSeconds)}];}
        if(n>=14&&(f[8]&128)){NSMutableString *hex=[NSMutableString string];for(size_t i=0;i<n;i++)[hex appendFormat:@"%02x",f[i]];[events addObject:@{@"ack_frame":hex}];}
        if(n==14&&f[4]==0x5a&&f[5]==2&&(f[8]&128)&&f[9]==0x5b&&(f[10]==1||f[10]==2)&&f[11]==0)acks.insert(f[6]|unsigned(f[7])<<8);
    };}
    template<class Done>void read(double seconds,Done done){auto end=std::chrono::steady_clock::now()+std::chrono::duration<double>(seconds);
        while(in&&std::chrono::steady_clock::now()<end){NSMutableData *data=[NSMutableData dataWithLength:2048];NSUInteger count=0;NSError *e=nil;BOOL ok=[in sendIORequestWithData:data bytesTransferred:&count completionTimeout:.08 error:&e];if(count)parser.append((const uint8_t*)data.bytes,count);if(done())return;if(!ok&&e.code!=(NSInteger)kIOReturnTimeout)return;}}
    bool write(unsigned setting,const std::vector<uint8_t>& value,uint16_t seq){auto frame=dji::tcPacket(seq,setting,value);NSUInteger sent=0;NSError *e=nil;
        BOOL ok=[out sendIORequestWithData:[NSMutableData dataWithBytes:frame.data() length:frame.size()] bytesTransferred:&sent completionTimeout:.3 error:&e];
        NSMutableString *hex=[NSMutableString string];for(auto b:frame)[hex appendFormat:@"%02x",b];[events addObject:@{@"setting":@(setting),@"sequence":@(seq),@"sent":@(sent),@"request":hex}];return ok&&sent==frame.size();}
    template<class Match>bool prepare(unsigned setting,uint8_t value,Match match){for(int attempt=0;attempt<2;attempt++){auto seq=sequence++;if(!write(setting,{value},seq))return false;read(.8,[&]{return acks.count(seq)&&match(telemetry.state);});if(acks.count(seq)&&match(telemetry.state))return true;}return false;}
};
static NSDictionary *syncTimecode(int argc,const char *argv[]){
    NSMutableDictionary *results=[NSMutableDictionary dictionary];bool success=false;std::string failure;double targetWall=0,targetHost=0;
    std::vector<std::unique_ptr<SyncEndpoint>> endpoints;
    try{
        std::string rate=argc>2?argv[2]:"";if(rate.size()!=1||rate[0]<'0'||rate[0]>'7'||argc<5||(argc-3)%2)throw std::runtime_error("TC同期の対象またはFPSが不正です。");int fps=rate[0]-'0';
        std::set<std::string> serials;std::set<uint64_t> ids;
        for(int i=3;i<argc;i+=2){std::string serial=argv[i],id=argv[i+1];if(!dji::validSerial(serial)||id.empty()||!std::all_of(id.begin(),id.end(),[](char c){return c>='0'&&c<='9';}))throw std::runtime_error("TC同期のUSB識別情報が不正です。");
            uint64_t registry=std::stoull(id);if(!registry||!serials.insert(serial).second||!ids.insert(registry).second)throw std::runtime_error("TC同期の対象が重複しています。");auto e=std::make_unique<SyncEndpoint>();e->serial=serial;e->registry=registry;e->bind();endpoints.push_back(std::move(e));}
        dji::USBControlLock guard(4000);if(!guard)throw std::runtime_error("USB制御が使用中です。");
        IteratorScope iteratorScope;IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostInterface"),&iteratorScope.value);io_service_t service;
        while((service=IOIteratorNext(iteratorScope.value))){CFMutableDictionaryRef raw=nullptr;IORegistryEntryCreateCFProperties(service,&raw,kCFAllocatorDefault,0);NSDictionary *p=CFBridgingRelease(raw);uint64_t id=parentID(service);
            auto found=std::find_if(endpoints.begin(),endpoints.end(),[&](auto& e){return e->registry==id;});
            if(found==endpoints.end()||[p[@"idVendor"] unsignedIntValue]!=0x2ca3||[p[@"idProduct"] unsignedIntValue]!=0x4115||[p[@"bInterfaceNumber"] unsignedIntValue]!=4||[p[@"bInterfaceClass"] unsignedIntValue]!=255){IOObjectRelease(service);continue;}
            auto& e=**found;NSError *error=nil;e.iface=[[IOUSBHostInterface alloc]initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];IOObjectRelease(service);if(!e.iface)continue;
            e.previous=e.iface.interfaceDescriptor?e.iface.interfaceDescriptor->bAlternateSetting:0;
            if(e.previous!=1&&![e.iface selectAlternateSetting:1 error:&error])throw std::runtime_error("TC同期のUSB接続を準備できません。");
            e.in=[e.iface copyPipeWithAddress:0x81 error:&error];e.out=[e.iface copyPipeWithAddress:1 error:&error];
        }
        // 設定を書き込む前に全対象を確認。registryはbridgeが同じ接続の実シリアルへ結び付けたもの。
        for(auto& e:endpoints){if(!e->in||!e->out)throw std::runtime_error("対象RXが抜去されました。TC同期を中止しました。");
            e->read(1.8,[&]{return dji::completeTelemetry(e->telemetry.state);});
            if(!dji::completeTelemetry(e->telemetry.state)||(!e->parser.identity.serial.empty()&&e->parser.identity.serial!=e->serial))throw std::runtime_error("対象RXの状態を確認できません。TC同期を中止しました。");
            if(e->telemetry.state.output==0)throw std::runtime_error("L-INのRXは外部TC入力です。出力をN/Aへ変更してから同期してください。");}
        for(auto& e:endpoints){if(!e->prepare(0x32,uint8_t(fps),[&](auto& s){return s.fps==fps;}))throw std::runtime_error("FPSの適用に失敗しました。時計の同期は行っていません。");
            if(!e->telemetry.state.tcEnabled&&!e->prepare(0x35,1,[](auto& s){return s.tcEnabled;}))throw std::runtime_error("TCを有効にできません。時計の同期は行っていません。");}
        // 全workerの起動余裕を確保。NDFはこの瞬間の壁時計へjamし、その後は選択FPSでfree-runする。
        targetWall=std::ceil(NSDate.date.timeIntervalSince1970+.5);double wall=NSDate.date.timeIntervalSince1970;
        auto deadline=std::chrono::steady_clock::now()+std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(targetWall-wall));targetHost=SyncEndpoint::host()+targetWall-wall;
        std::vector<std::thread> workers;workers.reserve(endpoints.size());
        try{for(auto& item:endpoints){auto *e=item.get();workers.emplace_back([&,e]{@autoreleasepool{try{
            auto clock=dji::tcWallClock(time_t(targetWall),fps,e->telemetry.state.clock[0]);std::this_thread::sleep_until(deadline);
            e->sentHost=SyncEndpoint::host();if(e->sentHost-targetHost>.02){e->error="TC送信時刻を超過しました。再同期してください。";return;}
            auto reset=e->sequence++;bool resetSent=e->write(0x2f,{1},reset);e->read(.5,[&]{return e->acks.count(reset);});
            // reset後はACKの有無にかかわらずclockを送信する。
            auto seq=e->sequence++;bool written=e->write(0x33,{clock.begin(),clock.end()},seq);e->finishedHost=SyncEndpoint::host();
            int reference=dji::tcFrames(dji::tcText(clock),fps);
            auto check=[&]{auto& s=e->telemetry.state;int observed=dji::tcFrames(s.timecode,fps);if(s.observedHostSeconds<=e->sentHost||observed<0)return false;
                e->errorFrames=dji::tcDelta(observed,reference+(s.observedHostSeconds-targetHost)*dji::tcRate(fps),fps);
                return s.tcEnabled&&s.fps==fps&&std::abs(e->errorFrames)<=2;};
            e->read(2.0,[&]{return e->acks.count(seq)&&check();});e->accepted=written&&e->acks.count(seq);e->verified=resetSent&&e->acks.count(reset)&&e->accepted&&check();
            if(!e->verified)e->error=e->accepted?"TCの位相または一致を確認できません。再同期してください。":"TC同期の応答を確認できません。";
        }catch(const std::exception& ex){e->error=ex.what();}}});}}
        catch(...){for(auto& worker:workers)worker.join();throw;}
        for(auto& worker:workers)worker.join();success=std::all_of(endpoints.begin(),endpoints.end(),[](auto& e){return e->verified;});
        if(!success)failure="一部のRXを同期できませんでした。各RXの状態を確認してください。";
    }catch(const std::exception& e){failure=e.what();}
    double first=1e30,last=0;
    for(auto& e:endpoints){if(e->sentHost){first=std::min(first,e->sentHost);last=std::max(last,e->sentHost);}
        results[@(e->serial.c_str())]=@{@"success":@(e->verified),@"message":@(e->error.empty()?(success?"":failure.c_str()):e->error.c_str()),@"status":jsonStatus(e->telemetry.state),@"accepted":@(e->accepted),@"error_frames":@(e->errorFrames),@"sent_host_seconds":@(e->sentHost),@"write_completed_host_seconds":@(e->finishedHost),@"events":e->events,@"sync":@{@"target_wall_seconds":@(targetWall),@"target_host_seconds":@(targetHost),@"sent_host_seconds":@(e->sentHost),@"error_frames":@(e->errorFrames)}};}
    return @{@"success":@(success),@"message":@(failure.c_str()),@"target_wall_seconds":@(targetWall),@"target_host_seconds":@(targetHost),@"send_spread_ms":@(last?1000*(last-first):0),@"receivers":results};
}
