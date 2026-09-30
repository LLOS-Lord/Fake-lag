#import <Foundation/Foundation.h>
#import <spawn.h>
#import <dlfcn.h>
#import <unistd.h>

// Helper to spawn with persona UID 0 for HUD daemon root
// Uses private API posix_spawnattr_set_persona_np via dlsym to avoid link error

int HybridSpawnWithPersona(uid_t uid, gid_t gid, const char *execPath, char *const argv[], char *const envp[], pid_t *outPID) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    
    // Try to set persona to root (99 is persona ID for root on iOS)
    // Use dlsym for private functions
    void *handle = dlopen(NULL, RTLD_NOW);
    if (handle) {
        // posix_spawnattr_set_persona_np
        int (*set_persona_np)(posix_spawnattr_t *, int, uint32_t) = dlsym(handle, "posix_spawnattr_set_persona_np");
        int (*set_persona_uid_np)(posix_spawnattr_t *, uid_t) = dlsym(handle, "posix_spawnattr_set_persona_uid_np");
        int (*set_persona_gid_np)(posix_spawnattr_t *, uid_t) = dlsym(handle, "posix_spawnattr_set_persona_gid_np");
        
        if (set_persona_np) {
            // 99 = root persona, flags 1 = override
            set_persona_np(&attr, 99, 1);
        }
        if (set_persona_uid_np) {
            set_persona_uid_np(&attr, uid);
        }
        if (set_persona_gid_np) {
            set_persona_gid_np(&attr, gid);
        }
        // dlclose not needed for NULL
    }
    
    // Set pgroup flag to avoid being killed with parent
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);
    
    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    
    int result = posix_spawn(outPID, execPath, &fileActions, &attr, argv, envp);
    
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fileActions);
    
    return result;
}

// C wrapper for Swift
int HybridSpawnRoot(const char *execPath, const char *arg1, const char *arg2) {
    pid_t pid = 0;
    const char *argv[4];
    argv[0] = execPath;
    argv[1] = arg1;
    argv[2] = arg2;
    argv[3] = NULL;
    
    extern char **environ;
    return HybridSpawnWithPersona(0, 0, execPath, (char *const *)argv, environ, &pid);
}
