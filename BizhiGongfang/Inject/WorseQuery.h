/*
     worse_query - A sandbox escape PoC for iOS 26 and 27, again.
     Copyright (C) 2026 Taj C (forcequit)

     This program is free software: you can redistribute it and/or modify
     it under the terms of the GNU General Public License as published by
     the Free Software Foundation, either version 3 of the License, or
     (at your option) any later version.

     This program is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
     GNU General Public License for more details.

     You should have received a copy of the GNU General Public License
     along with this program.  If not, see <https://www.gnu.org/licenses/>.

     Ported into 壁纸工坊, adapted by 壁纸工坊.
     Based on Placard's bundled worse_query.m (the safer variant that backs
     up Library/Caches and restores it after the query).
*/

#ifndef WorseQuery_h
#define WorseQuery_h

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

int64_t worse_query(NSString *target, NSString *group, bool alt_flags, bool create_dir);
int64_t worse_query_at_root(NSString *target, NSString *group, NSString *groupRoot, bool alt_flags, bool create_dir);
void worse_query_release(int64_t handle);

NS_ASSUME_NONNULL_END

#endif /* WorseQuery_h */
