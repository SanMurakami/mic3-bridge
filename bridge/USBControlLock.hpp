#pragma once
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <chrono>
#include <thread>
#include <string>
namespace dji {
// USB monitor と設定 process が同じ status stream を奪い合わないようにする。
class USBControlLock {
    int fd=-1;bool held=false;
public:
    explicit USBControlLock(unsigned waitMilliseconds=0){
        std::string path="/tmp/local.dji-mic.usb-"+std::to_string(getuid())+".lock";
        fd=open(path.c_str(),O_CREAT|O_RDWR|O_NOFOLLOW,0600);if(fd<0)return;
        auto start=std::chrono::steady_clock::now();
        do {if(!flock(fd,LOCK_EX|LOCK_NB)){held=true;break;}if(!waitMilliseconds)break;std::this_thread::sleep_for(std::chrono::milliseconds(20));}
        while(std::chrono::steady_clock::now()-start<std::chrono::milliseconds(waitMilliseconds));
    }
    explicit operator bool()const{return held;}
    ~USBControlLock(){if(fd>=0)close(fd);}
};
}
