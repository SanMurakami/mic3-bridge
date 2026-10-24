#include "../bridge/USBControlLock.hpp"
#include <cassert>
#include <atomic>
#include <cstdio>
int main(){
 using namespace std::chrono;
 std::atomic<bool> reading{false},release{false},waiting{false},writerDone{false};
 std::thread reader([&]{dji::USBControlLock first(0,true);assert(first);{dji::USBControlLock second(0,true);assert(second);}reading=true;while(!release)std::this_thread::yield();});
 while(!reading)std::this_thread::yield();
 std::thread writer([&]{waiting=true;dji::USBControlLock guard(1000);assert(guard);dji::USBControlLock blocked(0,true);assert(!blocked);writerDone=true;});
 while(!waiting)std::this_thread::yield();
 // writerのintent取得を観測するまで既存readerを維持。
 bool blocked=false;auto deadline=steady_clock::now()+milliseconds(500);
 while(steady_clock::now()<deadline){dji::USBControlLock probe(0,true);if(!probe){blocked=true;break;}}
 assert(blocked&&!writerDone);release=true;reader.join();writer.join();assert(writerDone);
 {dji::USBControlLock again(0,true);assert(again);dji::USBControlLock conflict(0);assert(!conflict);}
 {dji::USBControlLock final(100);assert(final);}
 puts("usb-lock: RX並列読取・writer優先・所有権解放 OK");
}
