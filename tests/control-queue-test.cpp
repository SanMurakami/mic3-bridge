#include "../bridge/ControlQueue.hpp"
#include <vector>
#include <cassert>
#include <cstdio>
struct Job {std::string serial,key;int value;bool started=false;};
int main(){
 std::vector<Job> jobs;
 auto add=[&](Job job){auto i=dji::pendingReplacement(jobs,job.serial,[&](auto& old){return old.key==job.key;});if(i<jobs.size())jobs[i]=job;else jobs.push_back(job);};
 // 大量のgain操作は、実行中の値と最後に要求した値だけを残す。
 add({"RX1","gain:TX1",0,true});for(int i=1;i<=1000;i++)add({"RX1","gain:TX1",i});
 assert(jobs.size()==2&&jobs[0].value==0&&jobs[1].value==1000);
 // 他RXの操作を消さず、同じRXのAGC変更を越えてgainをまとめない。
 add({"RX2","gain:TX1",5});add({"RX1","gain:TX1",1001});assert(jobs.size()==3&&jobs[1].value==1001&&jobs[2].value==5);
 add({"RX1","agc:TX1",0});add({"RX1","gain:TX1",3});add({"RX1","gain:TX1",4});
 assert(jobs.size()==5&&jobs[1].value==1001&&jobs[3].key=="agc:TX1"&&jobs[4].value==4);
 // TXが異なる操作と一括profileも独立した順序の境界。
 add({"RX1","gain:TX2",6});add({"RX1","gain:TX1",7});add({"RX1","profile",0});add({"RX1","gain:TX1",8});
 assert(jobs.size()==9&&jobs[5].key=="gain:TX2"&&jobs[6].value==7&&jobs[7].key=="profile"&&jobs[8].value==8);
 puts("control queue: gain連打の最新値、RX/TX独立、AGC/profileの順序保持 OK");
}
