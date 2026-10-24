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
#include "MicIdentity.hpp"
#include "MicTelemetry.hpp"
#include "USBControlLock.hpp"
namespace dji {
class USBIdentityMonitor {
    std::atomic<bool> running{true};
    std::mutex mutex;
    std::map<uint64_t,Identity> identities;
    std::map<uint64_t,Telemetry> telemetry;
    std::map<uint64_t,std::chrono::steady_clock::time_point> updated;
    std::set<uint64_t> refreshIDs;
    std::map<uint64_t,std::chrono::steady_clock::time_point> attempted;
    std::thread worker;
    static uint64_t parentID(io_service_t service) {
        io_registry_entry_t parent=0,current=service;IOObjectRetain(current);uint64_t id=0;
        while(IORegistryEntryGetParentEntry(current,kIOServicePlane,&parent)==KERN_SUCCESS){IOObjectRelease(current);current=parent;
            if(IOObjectConformsTo(current,"IOUSBHostDevice")){IORegistryEntryGetRegistryEntryID(current,&id);break;}}
        IOObjectRelease(current);return id;
    }
    void inspect(io_service_t service,uint64_t id) {@autoreleasepool{
        USBControlLock guard;if(!guard)return;
        NSError *error=nil;IOUSBHostInterface *interface=[[IOUSBHostInterface alloc] initWithIOService:service options:0 queue:nil error:&error interestHandler:nil];
        if(!interface)return;
        unsigned previous=interface.interfaceDescriptor?interface.interfaceDescriptor->bAlternateSetting:0;
        if(previous!=1&&![interface selectAlternateSetting:1 error:&error]){[interface destroy];return;}
        IOUSBHostPipe *pipe=[interface copyPipeWithAddress:0x81 error:&error];IdentityParser parser;
        TelemetryParser status;
        parser.onFrame=[&](const uint8_t *p,size_t n){status.frame(p,n);};
        auto start=std::chrono::steady_clock::now();
        while(pipe&&running&&(parser.identity.serial.empty()||std::chrono::steady_clock::now()-start<std::chrono::milliseconds(500))&&std::chrono::steady_clock::now()-start<std::chrono::seconds(2)){
            NSMutableData *data=[NSMutableData dataWithLength:2048];NSUInteger count=0;error=nil;
            BOOL ok=[pipe sendIORequestWithData:data bytesTransferred:&count completionTimeout:.2 error:&error];
            if(count)parser.append((const uint8_t*)data.bytes,count);
            if(!ok&&error.code!=(NSInteger)kIOReturnTimeout)break;
        }
        if(previous!=1)[interface selectAlternateSetting:previous error:nil];[interface destroy];
        if(!parser.identity.serial.empty()){std::lock_guard<std::mutex> lock(mutex);identities[id]=parser.identity;if(status.state.known){telemetry[id]=status.state;updated[id]=std::chrono::steady_clock::now();}refreshIDs.erase(id);}
    }}
    void loop(){while(running){@autoreleasepool{
        std::set<uint64_t> live;
        io_iterator_t iterator=0;
        if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostInterface"),&iterator)==KERN_SUCCESS){
            io_service_t service;
            while((service=IOIteratorNext(iterator))){
                CFMutableDictionaryRef raw=nullptr;IORegistryEntryCreateCFProperties(service,&raw,kCFAllocatorDefault,0);NSDictionary *p=CFBridgingRelease(raw);
                io_name_t name={0};IORegistryEntryGetName(service,name);
                if([p[@"idVendor"] unsignedIntValue]==0x2ca3&&[p[@"bInterfaceNumber"] unsignedIntValue]==4&&[p[@"bInterfaceClass"] unsignedIntValue]==255&&std::string(name)=="com.dji.mic"){
                    uint64_t id=parentID(service);if(id)live.insert(id);bool known=false;{std::lock_guard<std::mutex> lock(mutex);known=identities.count(id)&&!refreshIDs.count(id)&&updated.count(id)&&std::chrono::steady_clock::now()-updated[id]<std::chrono::seconds(3);}
                    auto now=std::chrono::steady_clock::now();
                    if(id&&!known&&(!attempted.count(id)||now-attempted[id]>std::chrono::seconds(3))){attempted[id]=now;inspect(service,id);}
                }
                IOObjectRelease(service);
            }
            IOObjectRelease(iterator);
        }
        {std::lock_guard<std::mutex> lock(mutex);for(auto it=identities.begin();it!=identities.end();)if(!live.count(it->first)){telemetry.erase(it->first);updated.erase(it->first);refreshIDs.erase(it->first);it=identities.erase(it);}else ++it;}
        for(auto it=attempted.begin();it!=attempted.end();)if(!live.count(it->first))it=attempted.erase(it);else ++it;
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }}}
public:
    USBIdentityMonitor():worker([this]{loop();}){}
    ~USBIdentityMonitor(){running=false;worker.join();}
    void observed(const std::string& serial,unsigned index,const std::string& mode){std::lock_guard<std::mutex> lock(mutex);for(auto& [id,identity]:identities)if(identity.serial==serial&&telemetry[id].transmitters.count(index))telemetry[id].transmitters[index].noise=mode;}
    void refresh(const std::string& serial){std::lock_guard<std::mutex> lock(mutex);for(auto& [id,identity]:identities)if(identity.serial==serial)refreshIDs.insert(id);}
    void update(const std::string& serial,const Telemetry& state){std::lock_guard<std::mutex> lock(mutex);for(auto& [id,identity]:identities)if(identity.serial==serial){telemetry[id]=state;updated[id]=std::chrono::steady_clock::now();}}
    Telemetry status(const std::string& serial){std::lock_guard<std::mutex> lock(mutex);for(auto& [id,identity]:identities)if(identity.serial==serial&&updated.count(id)&&std::chrono::steady_clock::now()-updated[id]<std::chrono::seconds(12))return telemetry[id];return {};}
    std::map<unsigned,std::string> controls(const std::string& serial){std::map<unsigned,std::string> result;for(auto& [index,tx]:status(serial).transmitters)result[index]=tx.noise;return result;}
    Identity get(uint64_t id){std::lock_guard<std::mutex> lock(mutex);auto found=identities.find(id);return found==identities.end()?Identity{}:found->second;}
};
}
