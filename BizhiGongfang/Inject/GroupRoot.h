//
//  GroupRoot.h
//  壁纸工坊
//
//  本文件为 壁纸工坊 自行实现（思路参考 WQFiles，未直接复制其代码）。
//  随项目以 GPL-3.0-or-later 发布。
//

#ifndef GroupRoot_h
#define GroupRoot_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 返回 App Group 的真实容器根目录（…/Shared/AppGroup/<UUID>）。
// 在 LiveContainer 内也能找到真正的目录而非替身目录；三路都失败时返回 nil。
NSString * _Nullable bizhi_group_root(NSString *group);

// 返回系统构建号（kern.osversion），如 @"24C5049d"；失败时返回 @""。
NSString *bizhi_os_build(void);

// 判断该构建号是否已修复 worse_query（Apple 在 iOS 27.3 beta 2 起修复）；
// 无法解析的构建号返回 NO。
BOOL bizhi_worse_query_patched_build(NSString *build);

// 把 "/var/…" 规范化为 "/private/var/…"，其它路径原样返回。
NSString *bizhi_canonical_var_path(NSString *path);

NS_ASSUME_NONNULL_END

#endif /* GroupRoot_h */
