//
//  GroupRoot.m
//  壁纸工坊
//
//  本文件为 壁纸工坊 自行实现（思路参考 WQFiles，未直接复制其代码）。
//  随项目以 GPL-3.0-or-later 发布。
//
//  目的：找出 App Group 的真实容器根目录。NSFileManager 给出的答案在
//  LiveContainer 内可能是替身目录（LiveContainer 自己的 App Group 下的
//  LiveContainer/Data/AppGroup/<id>），而 worse_query 的令牌是发给真实
//  目录的 Library/Caches 的，换错目录查询就会失败。所以按三路依次尝试：
//  先问一个不消费的令牌它覆盖哪条路径，再问容器管理器，最后才用
//  NSFileManager 的答案（并把替身目录映射回真实目录）。
//

#import "GroupRoot.h"
#include <dlfcn.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <xpc/xpc.h>

typedef void *(*bizhi_cq_create_fn)(void);
typedef void (*bizhi_cq_set_u64_fn)(void *, uint64_t);
typedef void (*bizhi_cq_set_ids_fn)(void *, xpc_object_t);
typedef void *(*bizhi_cq_result_fn)(void *);
typedef void (*bizhi_cq_free_fn)(void *);
typedef char *(*bizhi_cq_token_fn)(void *);
typedef void (*bizhi_cq_iterate_fn)(void *, bool (^)(void *));
typedef const char *(*bizhi_co_get_path_fn)(void *);

NSString *bizhi_canonical_var_path(NSString *path)
{
    if ([path isEqualToString:@"/var"] || [path hasPrefix:@"/var/"])
        return [@"/private" stringByAppendingString:path];
    return path;
}

static BOOL bizhi_is_dir(NSString *path)
{
    struct stat st;
    return path.length && lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
}

// 令牌覆盖的路径形如
// "/private/var/mobile/Containers/Shared/AppGroup/<一个名字>/Library/Caches"；
// 去掉 "/Library/Caches" 后缀即为 App Group 根目录，其它形状返回 nil。
static NSString *bizhi_group_root_from_token_path(NSString *path)
{
    if (!path.length) return nil;
    NSString *p = bizhi_canonical_var_path(path);
    if (![p hasSuffix:@"/Library/Caches"]) return nil;
    NSString *root = [p substringToIndex:p.length - @"/Library/Caches".length];
    if (![root.stringByDeletingLastPathComponent isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup"]) return nil;
    NSString *name = root.lastPathComponent;
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) return nil;
    return root;
}

// LiveContainer 的替身目录形如
// "<真实 App Group 根目录>/LiveContainer/Data/AppGroup/<id>"；
// 截掉替身部分，回到真实根目录。形状不对时原样返回传入的路径。
static NSString *bizhi_group_root_for_path(NSString *path)
{
    if (!path.length) return nil;
    NSRange lc = [path rangeOfString:@"/LiveContainer/Data/AppGroup/"];
    if (lc.location == NSNotFound) return path;
    NSString *real = [path substringToIndex:lc.location];
    NSString *parent = bizhi_canonical_var_path(real.stringByDeletingLastPathComponent);
    if (![parent isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup"]) return path;
    return real;
}

// 只问令牌、不消费它：发一次 class 7、part 3（Library/Caches）的查询，
// 拿到令牌后取它最后一个 ';' 之后的字段（即令牌覆盖的路径），
// 随即释放令牌和查询。先试标准 flags，再试 iOS 26 的另一组 flags。
// 注意：这里不做任何 Caches 交换，所以令牌不会被使用、也不会被消耗。
static NSString *bizhi_token_group_root(NSString *group)
{
    if (!group.length) return nil;
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return nil;
    bizhi_cq_create_fn create = (bizhi_cq_create_fn)dlsym(mgr, "container_query_create");
    bizhi_cq_set_u64_fn setClass = (bizhi_cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
    bizhi_cq_set_ids_fn setGroups = (bizhi_cq_set_ids_fn)dlsym(mgr, "container_query_set_group_identifiers");
    bizhi_cq_set_u64_fn setFlags = (bizhi_cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_flags");
    bizhi_cq_set_u64_fn setPart = (bizhi_cq_set_u64_fn)dlsym(mgr, "container_query_operation_set_part");
    bizhi_cq_result_fn single = (bizhi_cq_result_fn)dlsym(mgr, "container_query_get_single_result");
    bizhi_cq_free_fn freeQuery = (bizhi_cq_free_fn)dlsym(mgr, "container_query_free");
    bizhi_cq_token_fn copyToken = (bizhi_cq_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    NSString *covered = nil;
    if (create && setClass && setGroups && setFlags && setPart && single && freeQuery && copyToken) {
        static const uint64_t flags[2] = { 0x0000008000000000ULL, 0x0000000800000000ULL };
        for (int i = 0; i < 2 && !covered; i++) {
            void *query = create();
            if (!query) continue;
            char *token = NULL;
            setClass(query, 7); // App Group 容器
            setGroups(query, xpc_string_create(group.UTF8String));
            setPart(query, 3); // Library/Caches
            setFlags(query, flags[i]);
            void *result = single(query);
            if (result) token = copyToken(result);
            if (token) {
                NSString *text = @(token) ?: @"";
                NSRange last = [text rangeOfString:@";" options:NSBackwardsSearch];
                if (last.location != NSNotFound) covered = [text substringFromIndex:NSMaxRange(last)];
                free(token);
            }
            freeQuery(query);
        }
    }
    dlclose(mgr);
    return covered ? bizhi_group_root_from_token_path(covered) : nil;
}

// 问容器管理器：这个 App Group 的容器路径是什么。问不到时返回 nil。
static NSString *bizhi_cm_group_path(NSString *group)
{
    if (!group.length) return nil;
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return nil;
    bizhi_cq_create_fn create = (bizhi_cq_create_fn)dlsym(mgr, "container_query_create");
    bizhi_cq_set_u64_fn setClass = (bizhi_cq_set_u64_fn)dlsym(mgr, "container_query_set_class");
    bizhi_cq_set_ids_fn setGroups = (bizhi_cq_set_ids_fn)dlsym(mgr, "container_query_set_group_identifiers");
    bizhi_cq_iterate_fn iterate = (bizhi_cq_iterate_fn)dlsym(mgr, "container_query_iterate_results_sync");
    bizhi_cq_free_fn freeQuery = (bizhi_cq_free_fn)dlsym(mgr, "container_query_free");
    bizhi_co_get_path_fn getPath = (bizhi_co_get_path_fn)dlsym(mgr, "container_object_get_path");
    __block NSString *found = nil;
    if (create && setClass && setGroups && iterate && freeQuery && getPath) {
        void *query = create();
        if (query) {
            setClass(query, 7); // App Group 容器
            setGroups(query, xpc_string_create(group.UTF8String));
            iterate(query, ^bool(void *object) {
                const char *path = object ? getPath(object) : NULL;
                if (path && path[0]) { found = @(path); return false; }
                return true;
            });
            freeQuery(query);
        }
    }
    dlclose(mgr);
    return found.length ? found : nil;
}

NSString *bizhi_group_root(NSString *group)
{
    if (!group.length) return nil;
    static NSMutableDictionary<NSString *, NSString *> *roots;
    static NSObject *cacheLock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        roots = [NSMutableDictionary new];
        cacheLock = [NSObject new];
    });
    @synchronized (cacheLock) {
        if (roots[group]) return roots[group];
    }

    NSString *root = nil;
    // 1. 令牌实际覆盖的目录最可靠（LiveContainer 下尤其如此），
    //    但它必须是真实存在的目录才可用。
    NSString *tokenRoot = bizhi_token_group_root(group);
    if (tokenRoot && bizhi_is_dir(tokenRoot)) {
        root = tokenRoot;
        NSLog(@"[BizhiGongfang] App Group %@：令牌指向的目录为 %@", group, tokenRoot);
    } else if (tokenRoot) {
        NSLog(@"[BizhiGongfang] App Group %@：令牌指向 %@，但无法访问", group, tokenRoot);
    }
    // 2. 没有可用的令牌答案时，用容器管理器给出的路径。
    if (!root) {
        NSString *managed = bizhi_canonical_var_path(bizhi_cm_group_path(group) ?: @"");
        if (managed.length && bizhi_is_dir(managed)) {
            root = managed;
            NSLog(@"[BizhiGongfang] App Group %@：使用容器管理器给出的目录 %@", group, managed);
        }
    }
    // 3. 最后用 NSFileManager 的答案，并把 LiveContainer 替身目录映射回真实目录。
    if (!root) {
        NSString *fmPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group].path;
        NSString *mapped = bizhi_group_root_for_path(fmPath);
        if (mapped.length && ![mapped isEqualToString:fmPath]) {
            if (bizhi_is_dir(mapped)) {
                NSLog(@"[BizhiGongfang] App Group %@：LiveContainer 替身目录 %@，改用真实目录 %@", group, fmPath, mapped);
            } else {
                mapped = fmPath; // 映射出的目录不存在，退回原路径
            }
        }
        root = mapped;
    }
    if (!root) {
        NSLog(@"[BizhiGongfang] App Group %@：找不到可用的容器目录", group);
        return nil;
    }
    @synchronized (cacheLock) {
        roots[group] = root;
    }
    return root;
}

NSString *bizhi_os_build(void)
{
    char buffer[64] = {0};
    size_t size = sizeof(buffer);
    if (sysctlbyname("kern.osversion", buffer, &size, NULL, 0) != 0) return @"";
    return [NSString stringWithUTF8String:buffer] ?: @"";
}

// 构建号如 "24C5049d"：开头数字是大版本号，接着一个字母是版本系列，
// 再往后数字是构建号（beta 版是 5xxx，正式版低于 1000）。
// Apple 在 iOS 27.3 beta 2（24C5049d，beta 1 是 24C5037i）修复了 worse_query：
// 24C 系列中，24C5049 之前的 beta 版仍可用，其它构建都已修复；
// 更高的主版本或更高的系列字母同样视为已修复。无法解析时返回 NO。
BOOL bizhi_worse_query_patched_build(NSString *build)
{
    const char *s = build.UTF8String;
    if (!s) return NO;
    int major = 0, number = 0, digits = 0;
    while (*s >= '0' && *s <= '9') { major = major * 10 + (*s++ - '0'); digits++; }
    if (!digits || *s < 'A' || *s > 'Z') return NO;
    char train = *s++;
    digits = 0;
    while (*s >= '0' && *s <= '9' && digits < 6) { number = number * 10 + (*s++ - '0'); digits++; }
    if (!digits) return NO;
    if (major != 24) return major > 24;
    if (train != 'C') return train > 'C';
    return !(number >= 5000 && number < 5049);
}
