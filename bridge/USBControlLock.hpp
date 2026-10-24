#pragma once
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <chrono>
#include <thread>
#include <string>
namespace dji {
// monitor同士は異なるRXを並行受信。設定processは全RXの読み取りを一時停止する。
class USBControlLock {
    int fd=-1,intent=-1;bool held=false;
public:
    explicit USBControlLock(unsigned waitMilliseconds=0,bool shared=false){
        std::string path="/tmp/local.dji-mic.usb-"+std::to_string(getuid())+".lock";
        fd=open(path.c_str(),O_CREAT|O_RDWR|O_NOFOLLOW,0600);intent=open((path+".intent").c_str(),O_CREAT|O_RDWR|O_NOFOLLOW,0600);if(fd<0||intent<0)return;
        auto start=std::chrono::steady_clock::now();
        auto acquire=[&](int descriptor,int mode){do{if(!flock(descriptor,mode|LOCK_NB))return true;if(!waitMilliseconds)return false;std::this_thread::sleep_for(std::chrono::milliseconds(5));}while(std::chrono::steady_clock::now()-start<std::chrono::milliseconds(waitMilliseconds));return false;};
        if(shared){
            // intentのチェック中だけSHを保持する。writerは現在のread(最大80ms)終了後に必ず進める。
            if(flock(intent,LOCK_SH|LOCK_NB))return;flock(intent,LOCK_UN);
            held=!flock(fd,LOCK_SH|LOCK_NB);
        }else if(acquire(intent,LOCK_EX))held=acquire(fd,LOCK_EX);
    }
    explicit operator bool()const{return held;}
    ~USBControlLock(){if(fd>=0)close(fd);if(intent>=0)close(intent);}
};
}
