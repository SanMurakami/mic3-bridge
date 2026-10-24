#pragma once
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include <atomic>
#include <chrono>
#include <map>
#include <set>
#include <mutex>
#include <thread>
#include <memory>
#include <mach/mach_time.h>
#include "MicIdentity.hpp"
#include "MicTelemetry.hpp"
#include "USBControlLock.hpp"
namespace dji {
class USBIdentityMonitor {
    std::atomic<bool> running{true};std::mutex mutex;
    std::map<uint64_t,Identity> identities;
    std::map<uint64_t,Telemetry> telemetry;
    std::map<uint64_t,std::chrono::steady_clock::time_point> updated;
    std::map<uint64_t,uint64_t> generations;
    static double host(){mach_timebase_info_data_t t;mach_timebase_info(&t);return mach_absolute_time()*(double)t.numer/t.denom/1e9;}
    static uint64_t parentID(io_service_t service){io_registry_entry_t parent=0,current=service;IOObjectRetain(current);uint64_t id=0;
        while(IORegistryEntryGetParentEntry(current,kIOServicePlane,&parent)==KERN_SUCCESS){IOObjectRelease(current);current=parent;if(IOObjectConformsTo(current,"IOUSBHostDevice")){IORegistryEntryGetRegistryEntryID(current,&id);break;}}IOObjectRelease(current);return id;}
    struct Reader {
        USBIdentityMonitor& owner;uint64_t id;io_service_t service;std::atomic<bool> alive{true};std::thread worker;
        Reader(USBIdentityMonitor& owner,uint64_t id,io_service_t service):owner(owner),id(id),service(service){IOObjectRetain(service);worker=std::thread([this]{run();});}
        ~Reader(){alive=false;worker.join();IOObjectRelease(service);}
        void run(){@autoreleasepool{
            IOUSBHostInterface *iface=nil;IOUSBHostPipe *pipe=nil;unsigned previous=0;
            std::unique_ptr<USBControlLock> lease;
            auto closeInterface=[&]{if(iface){if(previous!=1)[iface selectAlternateSetting:previous error:nil];[iface destroy];iface=nil;pipe=nil;}lease.reset();};
            IdentityParser parser;TelemetryParser state;Identity identity;uint64_t generation=0;bool resumed=true,warm=false;
            parser.onFrame=[&](const uint8_t *p,size_t n){
                if(!parser.identity.serial.empty())identity=parser.identity;
                auto revision=state.clockRevision;state.frame(p,n);bool clockArrived=state.clockRevision!=revision;std::lock_guard<std::mutex> lock(owner.mutex);
                if(!identity.serial.empty())owner.identities[id]=identity;
                // 受信再開時の滞留通知を排出してからclock anchorを更新する。
                if(!warm||!state.state.known||identity.serial.empty())return;
                auto old=owner.telemetry.find(id);
                observeTelemetryClock(state.state,old==owner.telemetry.end()?Telemetry{}:old->second,clockArrived,host());
                owner.telemetry[id]=state.state;owner.updated[id]=std::chrono::steady_clock::now();
            };
            while(alive&&owner.running){@autoreleasepool{
                bool retry=false;
                {
                    if(lease&&lease->writerWaiting()){closeInterface();resumed=true;warm=false;}
                    if(!lease){auto candidate=std::make_unique<USBControlLock>(0,true);if(*candidate)lease=std::move(candidate);}
                    if(!lease){resumed=true;retry=true;}
                    else {
                        if(!iface){NSError *error=nil;iface=[[IOUSBHostInterface alloc]initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];
                            if(iface){previous=iface.interfaceDescriptor?iface.interfaceDescriptor->bAlternateSetting:0;
                                if(previous!=1&&![iface selectAlternateSetting:1 error:&error]){[iface destroy];iface=nil;}
                                else pipe=[iface copyPipeWithAddress:0x81 error:&error];}
                            if(!pipe){closeInterface();retry=true;}
                        }
                        if(pipe){
                            {std::lock_guard<std::mutex> lock(owner.mutex);auto version=owner.generations[id];if(resumed||generation!=version){
                                auto found=owner.telemetry.find(id);if(found!=owner.telemetry.end())state.seed(found->second);
                                auto foundIdentity=owner.identities.find(id);if(foundIdentity!=owner.identities.end())identity=foundIdentity->second;
                                generation=version;parser.discardPending();warm=false;resumed=false;
                            }}
                            NSMutableData *data=[NSMutableData dataWithLength:2048];NSUInteger count=0;NSError *error=nil;auto before=host();
                            BOOL ok=[pipe sendIORequestWithData:data bytesTransferred:&count completionTimeout:.08 error:&error];
                            if(host()-before>.002||!count)warm=true;
                            if(count)parser.append((const uint8_t*)data.bytes,count);
                            if(!ok&&error.code!=(NSInteger)kIOReturnTimeout){closeInterface();warm=false;resumed=true;retry=true;}
                        }
                    }
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(retry?10:1));
            }}
            // interfaceを閉じてからleaseを返すので、次の設定processと所有権が重ならない。
            closeInterface();
        }}
    };
    std::map<uint64_t,std::unique_ptr<Reader>> readers;std::thread supervisor;
    void loop(){while(running){@autoreleasepool{
        std::set<uint64_t> live;io_iterator_t iterator=0;
        if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostInterface"),&iterator)==KERN_SUCCESS){io_service_t service;
            while((service=IOIteratorNext(iterator))){CFMutableDictionaryRef raw=nullptr;IORegistryEntryCreateCFProperties(service,&raw,kCFAllocatorDefault,0);NSDictionary *p=CFBridgingRelease(raw);io_name_t name={0};IORegistryEntryGetName(service,name);
                if([p[@"idVendor"] unsignedIntValue]==0x2ca3&&[p[@"idProduct"] unsignedIntValue]==0x4115&&[p[@"bInterfaceNumber"] unsignedIntValue]==4&&[p[@"bInterfaceClass"] unsignedIntValue]==255&&std::string(name)=="com.dji.mic"){
                    auto id=parentID(service);if(id){live.insert(id);if(!readers.count(id))readers[id]=std::make_unique<Reader>(*this,id,service);}}
                IOObjectRelease(service);
            }IOObjectRelease(iterator);
        }
        for(auto it=readers.begin();it!=readers.end();)if(!live.count(it->first))it=readers.erase(it);else ++it;
        {std::lock_guard<std::mutex> lock(mutex);for(auto it=identities.begin();it!=identities.end();)if(!live.count(it->first)){telemetry.erase(it->first);updated.erase(it->first);generations.erase(it->first);it=identities.erase(it);}else ++it;}
        for(int i=0;i<25&&running;i++)std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }}readers.clear();}
public:
    USBIdentityMonitor():supervisor([this]{loop();}){}
    ~USBIdentityMonitor(){running=false;supervisor.join();}
    void observed(const std::string& serial,unsigned index,const std::string& mode){std::lock_guard<std::mutex> lock(mutex);for(auto& [id,identity]:identities)if(identity.serial==serial&&telemetry[id].transmitters.count(index))telemetry[id].transmitters[index].noise=mode;}
    void refresh(const std::string& serial){std::lock_guard<std::mutex> lock(mutex);for(auto& [id,identity]:identities)if(identity.serial==serial)generations[id]++;}
    void update(const std::string& serial,const Telemetry& state){std::lock_guard<std::mutex> lock(mutex);for(auto& [id,identity]:identities)if(identity.serial==serial){telemetry[id]=state;updated[id]=std::chrono::steady_clock::now();generations[id]++;}}
    Telemetry status(const std::string& serial){std::lock_guard<std::mutex> lock(mutex);for(auto& [id,identity]:identities)if(identity.serial==serial&&updated.count(id)&&std::chrono::steady_clock::now()-updated[id]<std::chrono::seconds(12))return telemetry[id];return {};}
    std::map<unsigned,std::string> controls(const std::string& serial){std::map<unsigned,std::string> result;for(auto& [index,tx]:status(serial).transmitters)result[index]=tx.noise;return result;}
    Identity get(uint64_t id){std::lock_guard<std::mutex> lock(mutex);auto it=identities.find(id);return it==identities.end()?Identity{}:it->second;}
};
}
