#import <Foundation/Foundation.h>

int HybridSpawnWithPersona(uid_t uid, gid_t gid, const char *execPath, char *const argv[], char *const envp[], pid_t *outPID);
int HybridSpawnRoot(const char *execPath, const char *arg1, const char *arg2);
