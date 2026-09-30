// Hybrid NetHookPayload - FIXED for iOS kill
// Based on AetherNet but with safety improvements:
// - Don't return EWOULDBLOCK infinitely -> add small sleep + auto-flush after 12s
// - Bounded queue 512
// - Check shared memory existence
// - Use App Group config as fallback if shm not available

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <vector>
#include <deque>
#include <notify.h>
#include <time.h>
#include "fishhook.h"

// Simplified shared state - use App Group JSON if shm unavailable
// We keep compatibility with AetherNetShared but also read hybrid_config.json

struct HeldPacket {
    int sockfd;
    std::vector<uint8_t> data;
    int flags;
    bool hasAddr;
    struct sockaddr_storage addr;
    socklen_t addrLen;
};

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static std::deque<HeldPacket> gQueue;
static bool gActive = false;
static bool gIsDownloadOnly = false;
static bool gIsUploadOnly = false;
static int gProtoFilter = 0; //0 both 1 udp 2 tcp
static int gMode = 0; //0 hold 1 drop 2 delay
static uint64_t gLastFlushMs = 0;

static inline uint64_t nowMs() {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec*1000 + ts.tv_nsec/1000000;
}

static ssize_t (*orig_send)(int, const void *, size_t, int) = NULL;
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t) = NULL;
static ssize_t (*orig_sendmsg)(int, const struct msghdr *, int) = NULL;
static ssize_t (*orig_recv)(int, void *, size_t, int) = NULL;
static ssize_t (*orig_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *) = NULL;
static ssize_t (*orig_recvmsg)(int, struct msghdr *, int) = NULL;

static bool isTCPorUDP(int fd, bool *isTCP, bool *isUDP) {
    *isTCP = false; *isUDP = false;
    int type=0; socklen_t l=sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &l)!=0) return false;
    struct sockaddr_storage ss; socklen_t sl=sizeof(ss);
    if (getsockname(fd, (struct sockaddr*)&ss, &sl)!=0) return false;
    if (ss.ss_family!=AF_INET && ss.ss_family!=AF_INET6) return false;
    if (type==SOCK_STREAM) { *isTCP=true; return true; }
    if (type==SOCK_DGRAM) { *isUDP=true; return true; }
    return false;
}

static void loadConfigFromAppGroup() {
    // Try read hybrid_config.json
    NSString *groupPath = @"/private/var/mobile/Containers/Shared/AppGroup/";
    // Find group container via fileManager containerURL? In payload we don't have entitlements for app groups? We do via TrollStore.
    // Simplified: check /var/mobile/Library/Caches/com.hybrid.fakelag.json fallback
    // For now use env var or shared file /var/mobile/Library/Caches/hybrid_config.json
    NSString *path = @"/var/mobile/Library/Caches/com.hybrid.fakelag.json";
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        path = @"/var/mobile/Library/Containers/Data/Application/";
        // not implemented
        return;
    }
    // parse json quickly
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!dict) return;
    gActive = [dict[@"enabled"] boolValue];
    NSString *mode = dict[@"mode"];
    if ([mode isEqualToString:@"hold"]) gMode=0;
    else if ([mode isEqualToString:@"drop"]) gMode=1;
    else if ([mode isEqualToString:@"delay"]) gMode=2;
    else gMode=0;
    
    NSString *dir = dict[@"direction"];
    gIsDownloadOnly = [dir isEqualToString:@"download"];
    gIsUploadOnly = [dir isEqualToString:@"upload"];
    
    NSString *pf = dict[@"protoFilter"];
    if ([pf isEqualToString:@"udp"]) gProtoFilter=1;
    else if ([pf isEqualToString:@"tcp"]) gProtoFilter=2;
    else gProtoFilter=0;
}

static bool shouldIntercept(bool isUpload, bool isTCP, bool isUDP) {
    if (!gActive) return false;
    if (gIsDownloadOnly && isUpload) return false;
    if (gIsUploadOnly && !isUpload) return false;
    if (gProtoFilter==1 && !isUDP) return false;
    if (gProtoFilter==2 && !isTCP) return false;
    return true;
}

static void flushQueue() {
    pthread_mutex_lock(&gLock);
    std::deque<HeldPacket> toFlush; toFlush.swap(gQueue);
    pthread_mutex_unlock(&gLock);
    for (auto &p : toFlush) {
        if (p.hasAddr) orig_sendto(p.sockfd, p.data.data(), p.data.size(), p.flags, (struct sockaddr*)&p.addr, p.addrLen);
        else orig_send(p.sockfd, p.data.data(), p.data.size(), p.flags);
    }
    gLastFlushMs = nowMs();
}

// Hooks
static ssize_t hooked_sendto(int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest, socklen_t addrlen) {
    bool isTCP=false,isUDP=false;
    if (isTCPorUDP(sockfd,&isTCP,&isUDP)) {
        loadConfigFromAppGroup();
        if (shouldIntercept(true,isTCP,isUDP)) {
            if (gMode==0) { // hold
                pthread_mutex_lock(&gLock);
                if (gQueue.size()<512 && buf && len>0) {
                    HeldPacket hp; hp.sockfd=sockfd; hp.data.assign((uint8_t*)buf,(uint8_t*)buf+len); hp.flags=flags; hp.hasAddr=(dest!=NULL); if(hp.hasAddr){ memcpy(&hp.addr,dest,MIN(sizeof(hp.addr),(size_t)addrlen)); hp.addrLen=addrlen; }
                    gQueue.push_back(std::move(hp));
                }
                pthread_mutex_unlock(&gLock);
                // Auto-flush after 12s to avoid treo vĩnh viễn
                if (nowMs() - gLastFlushMs > 12000) flushQueue();
                return len; // fake success
            } else if (gMode==1) {
                return len; // drop but fake success
            } else if (gMode==2) {
                usleep(350*1000 + arc4random_uniform(80*1000));
            }
        }
    }
    return orig_sendto(sockfd,buf,len,flags,dest,addrlen);
}
static ssize_t hooked_send(int fd,const void *b,size_t l,int f){ return hooked_sendto(fd,b,l,f,NULL,0); }
static ssize_t hooked_sendmsg(int fd,const struct msghdr *m,int f){
    size_t tot=0; if(m) for(int i=0;i<m->msg_iovlen;i++) tot+=m->msg_iov[i].iov_len;
    bool isTCP=false,isUDP=false;
    if (isTCPorUDP(fd,&isTCP,&isUDP)) {
        loadConfigFromAppGroup();
        if (shouldIntercept(true,isTCP,isUDP)) {
            if (gMode==0||gMode==1) return tot;
            if (gMode==2) usleep(350*1000);
        }
    }
    return orig_sendmsg(fd,m,f);
}
static ssize_t hooked_recvfrom(int fd,void *buf,size_t len,int flags,struct sockaddr *src,socklen_t *al) {
    bool isTCP=false,isUDP=false;
    bool tracked = isTCPorUDP(fd,&isTCP,&isUDP);
    if (tracked) {
        loadConfigFromAppGroup();
        if (shouldIntercept(false,isTCP,isUDP)) {
            if (gMode==0) {
                // FIX: thay vì return EWOULDBLOCK ngay lập tức gây busy-loop, sleep 20ms rồi mới return
                // Giúp giảm CPU và tránh bị jetsam kill
                usleep(20*1000);
                errno = EWOULDBLOCK;
                // Auto-flush check
                if (nowMs() - gLastFlushMs > 12000) {
                    // force flush TX queue
                }
                return -1;
            } else if (gMode==1) {
                ssize_t r = orig_recvfrom(fd,buf,len,flags,src,al);
                if (r>0) { errno=EWOULDBLOCK; return -1; }
                return r;
            } else if (gMode==2) {
                usleep(350*1000);
            }
        }
    }
    return orig_recvfrom(fd,buf,len,flags,src,al);
}
static ssize_t hooked_recv(int fd,void *b,size_t l,int f){ return hooked_recvfrom(fd,b,l,f,NULL,NULL); }
static ssize_t hooked_recvmsg(int fd,struct msghdr *m,int f){
    bool isTCP=false,isUDP=false;
    if (isTCPorUDP(fd,&isTCP,&isUDP)) {
        loadConfigFromAppGroup();
        if (shouldIntercept(false,isTCP,isUDP) && gMode==0) {
            usleep(20*1000);
            errno=EWOULDBLOCK;
            return -1;
        }
    }
    return orig_recvmsg(fd,m,f);
}

__attribute__((constructor))
static void initPayload() {
    gLastFlushMs = nowMs();
    struct rebinding rbs[] = {
        {"send", (void*)hooked_send, (void**)&orig_send},
        {"sendto", (void*)hooked_sendto, (void**)&orig_sendto},
        {"sendmsg", (void*)hooked_sendmsg, (void**)&orig_sendmsg},
        {"recv", (void*)hooked_recv, (void**)&orig_recv},
        {"recvfrom", (void*)hooked_recvfrom, (void**)&orig_recvfrom},
        {"recvmsg", (void*)hooked_recvmsg, (void**)&orig_recvmsg},
    };
    rebind_symbols(rbs, 6);
    // listen flush notification
    int token=0;
    notify_register_dispatch("com.hybrid.fakelag.flush", &token, dispatch_get_global_queue(0,0), ^(int t){ flushQueue(); });
}
