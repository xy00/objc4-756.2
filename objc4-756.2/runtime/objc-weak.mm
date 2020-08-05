/*
 * Copyright (c) 2010-2011 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#include "objc-private.h"

#include "objc-weak.h"

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <libkern/OSAtomic.h>

#define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)

static void append_referrer(weak_entry_t *entry, objc_object **new_referrer);

BREAKPOINT_FUNCTION(
    void objc_weak_error(void)
);

static void bad_weak_table(weak_entry_t *entries)
{
    _objc_fatal("bad weak table at %p. This may be a runtime bug or a "
                "memory error somewhere else.", entries);
}

/** 
 * Unique hash function for object pointers only.
 * 
 * @param key The object pointer
 * 
 * @return Size unrestricted hash of pointer.
 */
static inline uintptr_t hash_pointer(objc_object *key) {
    return ptr_hash((uintptr_t)key);
}

/** 
 * Unique hash function for weak object pointers only.
 * 
 * @param key The weak object pointer. 
 * 
 * @return Size unrestricted hash of pointer.
 */
static inline uintptr_t w_hash_pointer(objc_object **key) {
    return ptr_hash((uintptr_t)key);
}

/** 
 * Grow the entry's hash table of referrers. Rehashes each
 * of the referrers.
 * 
 * @param entry Weak pointer hash set for a particular object.
 */
__attribute__((noinline, used))
static void grow_refs_and_insert(weak_entry_t *entry, 
                                 objc_object **new_referrer)
{
    assert(entry->out_of_line());

    size_t old_size = TABLE_SIZE(entry);
    size_t new_size = old_size ? old_size * 2 : 8;

    size_t num_refs = entry->num_refs;
    weak_referrer_t *old_refs = entry->referrers;
    entry->mask = new_size - 1;
    
    entry->referrers = (weak_referrer_t *)
        calloc(TABLE_SIZE(entry), sizeof(weak_referrer_t));
    entry->num_refs = 0;
    entry->max_hash_displacement = 0;
    
    for (size_t i = 0; i < old_size && num_refs > 0; i++) {
        if (old_refs[i] != nil) {
            append_referrer(entry, old_refs[i]);
            num_refs--;
        }
    }
    // Insert
    append_referrer(entry, new_referrer);
    if (old_refs) free(old_refs);
}

/** 
 * Add the given referrer to set of weak pointers in this entry.
 * Does not perform duplicate checking (b/c weak pointers are never
 * added to a set twice). 
 *
 * @param entry The entry holding the set of weak pointers. 
 * @param new_referrer The new weak pointer to be added.
 */
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer)
{
    if (! entry->out_of_line()) {
        // Try to insert inline.
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            if (entry->inline_referrers[i] == nil) {
                entry->inline_referrers[i] = new_referrer;
                return;
            }
        }

        // 如果 inline_referrers 的位置已经满了，就需要转为 referrers 存储
        // Couldn't insert inline. Allocate out of line.
        weak_referrer_t *new_referrers = (weak_referrer_t *)calloc(WEAK_INLINE_COUNT, sizeof(weak_referrer_t));
        // This constructed table is invalid, but grow_refs_and_insert
        // will fix it and rehash it.
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            new_referrers[i] = entry->inline_referrers[i];
        }
        entry->referrers = new_referrers;
        entry->num_refs = WEAK_INLINE_COUNT;
        entry->out_of_line_ness = REFERRERS_OUT_OF_LINE;
        entry->mask = WEAK_INLINE_COUNT-1;
        entry->max_hash_displacement = 0;
    }

    assert(entry->out_of_line());

    // 扩容并插入
    if (entry->num_refs >= TABLE_SIZE(entry) * 3/4) {
        return grow_refs_and_insert(entry, new_referrer);
    }
    // 不需要扩容插入
    size_t begin = w_hash_pointer(new_referrer) & (entry->mask);    // 获取起始位置
    size_t index = begin;   // 起始位置
    size_t hash_displacement = 0;
    while (entry->referrers[index] != nil) {    // index 的位置不为空，尝试插入到下一个位置
        hash_displacement++;    // 增加冲突次数
        index = (index+1) & entry->mask;    // 移动 index 到下一个位置
        if (index == begin) bad_weak_table(entry);  // 此时表示数组绕了一圈都没有空位置，触发异常机制
    }
    // 记录最大的冲突数，方便查找的时候使用。
    // 查找的时候如果超过了这个最大冲突数字，表示没有查找到
    if (hash_displacement > entry->max_hash_displacement) {
        entry->max_hash_displacement = hash_displacement;
    }
    
    // 将 new_referrer 存入 hash 数组，同时更新元素个数
    weak_referrer_t &ref = entry->referrers[index];
    ref = new_referrer;
    entry->num_refs++;
}

/** 
 * Remove old_referrer from set of referrers, if it's present.
 * Does not remove duplicates, because duplicates should not exist. 
 * 
 * @todo this is slow if old_referrer is not present. Is this ever the case? 
 *
 * @param entry The entry holding the referrers.
 * @param old_referrer The referrer to remove. 
 */
static void remove_referrer(weak_entry_t *entry, objc_object **old_referrer)
{
    // 使用 inline_referrers 方式存储
    if (! entry->out_of_line()) {
        // 循环找到并删除
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            if (entry->inline_referrers[i] == old_referrer) {
                entry->inline_referrers[i] = nil;
                return;
            }
        }
        _objc_inform("Attempted to unregister unknown __weak variable "
                     "at %p. This is probably incorrect use of "
                     "objc_storeWeak() and objc_loadWeak(). "
                     "Break on objc_weak_error to debug.\n", 
                     old_referrer);
        // 没有找到就触发异常
        objc_weak_error();
        return;
    }

    size_t begin = w_hash_pointer(old_referrer) & (entry->mask);    // 获取开始位置
    size_t index = begin;
    size_t hash_displacement = 0;
    while (entry->referrers[index] != old_referrer) { // 判断 index 位置是否为 old_referrer
        index = (index+1) & entry->mask;   // 如果不是就移动到 index 的下一个位置
        if (index == begin) bad_weak_table(entry);  // index 和 begin 相等表示已经循环了一圈，触发异常
        hash_displacement++;    // 冲突次数 + 1
        // 如果冲突次数大于最大冲突次数，表示没有找到，触发异常
        if (hash_displacement > entry->max_hash_displacement) {
            _objc_inform("Attempted to unregister unknown __weak variable "
                         "at %p. This is probably incorrect use of "
                         "objc_storeWeak() and objc_loadWeak(). "
                         "Break on objc_weak_error to debug.\n", 
                         old_referrer);
            objc_weak_error();
            return;
        }
    }
    // 删除找到的 old_referrer
    entry->referrers[index] = nil;
    // 元素个数 - 1
    entry->num_refs--;
}

/** 
 * Add new_entry to the object's table of weak references.
 * Does not check whether the referent is already in the table.
 */
static void weak_entry_insert(weak_table_t *weak_table, weak_entry_t *new_entry)
{
    weak_entry_t *weak_entries = weak_table->weak_entries;
    assert(weak_entries != nil);

    size_t begin = hash_pointer(new_entry->referent) & (weak_table->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    while (weak_entries[index].referent != nil) {
        index = (index+1) & weak_table->mask;
        if (index == begin) bad_weak_table(weak_entries);
        hash_displacement++;
    }

    weak_entries[index] = *new_entry;
    weak_table->num_entries++;

    // 调整最大冲突数
    if (hash_displacement > weak_table->max_hash_displacement) {
        weak_table->max_hash_displacement = hash_displacement;
    }
}


static void weak_resize(weak_table_t *weak_table, size_t new_size)
{
    size_t old_size = TABLE_SIZE(weak_table);

    weak_entry_t *old_entries = weak_table->weak_entries;
    weak_entry_t *new_entries = (weak_entry_t *)
        calloc(new_size, sizeof(weak_entry_t));

    weak_table->mask = new_size - 1;
    weak_table->weak_entries = new_entries;
    weak_table->max_hash_displacement = 0;
    weak_table->num_entries = 0;  // restored by weak_entry_insert below
    
    if (old_entries) {
        weak_entry_t *entry;
        weak_entry_t *end = old_entries + old_size;
        for (entry = old_entries; entry < end; entry++) {
            if (entry->referent) {
                weak_entry_insert(weak_table, entry);
            }
        }
        free(old_entries);
    }
}

// Grow the given zone's table of weak references if it is full.
static void weak_grow_maybe(weak_table_t *weak_table)
{
    size_t old_size = TABLE_SIZE(weak_table);

    // Grow if at least 3/4 full.
    if (weak_table->num_entries >= old_size * 3 / 4) {
        weak_resize(weak_table, old_size ? old_size*2 : 64);
    }
}

// Shrink the table if it is mostly empty.
static void weak_compact_maybe(weak_table_t *weak_table)
{
    size_t old_size = TABLE_SIZE(weak_table);

    // Shrink if larger than 1024 buckets and at most 1/16 full.
    if (old_size >= 1024  && old_size / 16 >= weak_table->num_entries) {
        weak_resize(weak_table, old_size / 8);
        // leaves new table no more than 1/2 full
    }
}


/**
 * Remove entry from the zone's table of weak references.
 */
static void weak_entry_remove(weak_table_t *weak_table, weak_entry_t *entry)
{
    // remove entry
    if (entry->out_of_line()) free(entry->referrers);
    bzero(entry, sizeof(*entry));

    weak_table->num_entries--;

    weak_compact_maybe(weak_table);
}


/** 
 * Return the weak reference table entry for the given referent. 
 * If there is no entry for referent, return NULL. 
 * Performs a lookup.
 *
 * @param weak_table 
 * @param referent The object. Must not be nil.
 * 
 * @return The table of weak referrers to this object. 
 */
static weak_entry_t *
weak_entry_for_referent(weak_table_t *weak_table, objc_object *referent)
{
    assert(referent);

    weak_entry_t *weak_entries = weak_table->weak_entries;

    if (!weak_entries) return nil;

    size_t begin = hash_pointer(referent) & weak_table->mask;   // 起始位置
    size_t index = begin;
    size_t hash_displacement = 0;   // 冲突次数
    while (weak_table->weak_entries[index].referent != referent)    // 如果index 位置不是 referent，就向后一个查找
    {
        index = (index+1) & weak_table->mask;
        if (index == begin) {
            bad_weak_table(weak_table->weak_entries);   // 异常场景
        }
        hash_displacement++;
        if (hash_displacement > weak_table->max_hash_displacement) {
            // 冲突次数超过了 max_hash_displacement，说明该元素没有在 hash 表中
            return nil;
        }
    }
    
    return &weak_table->weak_entries[index];
}

/** 
 * Unregister an already-registered weak reference.
 * This is used when referrer's storage is about to go away, but referent
 * isn't dead yet. (Otherwise, zeroing referrer later would be a
 * bad memory access.)
 * Does nothing if referent/referrer is not a currently active weak reference.
 * Does not zero referrer.
 * 
 * FIXME currently requires old referent value to be passed in (lame)
 * FIXME unregistration should be automatic if referrer is collected
 * 
 * @param weak_table The global weak table.
 * @param referent The object.
 * @param referrer The weak reference.
 */
void
weak_unregister_no_lock(weak_table_t *weak_table, id referent_id, id *referrer_id)
{
    objc_object *referent = (objc_object *)referent_id;
    objc_object **referrer = (objc_object **)referrer_id;

    weak_entry_t *entry;

    if (!referent) return;

    // 查找 referent 对应的 weak_entry_t
    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        remove_referrer(entry, referrer);  // 在 weak_entry_t 中移除 referrer
        // 遗传 referrer 以后，需要检查 weak_entry_t 中的 hash 数组是否已经空了
        bool empty = true;
        if (entry->out_of_line()  &&  entry->num_refs != 0)
        {
            empty = false;
        }
        else
        {
            for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
                if (entry->inline_referrers[i]) {
                    empty = false; 
                    break;
                }
            }
        }

        // 如果 weak_entry_t 的 hash 数组为空，需要将 weak_entry_t 从 weak_table 中移除
        if (empty) {
            weak_entry_remove(weak_table, entry);
        }
    }

    // Do not set *referrer = nil. objc_storeWeak() requires that the 
    // value not change.
}

/** 
 * Registers a new (object, weak pointer) pair. Creates a new weak
 * object entry if it does not exist.
 * 
 * @param weak_table The global weak table.
 * @param referent The object pointed to by the weak reference.
 * @param referrer The weak pointer address.
 */
id 
weak_register_no_lock(weak_table_t *weak_table, id referent_id, 
                      id *referrer_id, bool crashIfDeallocating)
{
    objc_object *referent = (objc_object *)referent_id;
    objc_object **referrer = (objc_object **)referrer_id;

    // referent 为空，或者 referent 采用了 TaggedPointer 计数方式，直接返回，不做任何操作
    if (!referent  ||  referent->isTaggedPointer()) return referent_id;

    // ensure that the referenced object is viable
    // 确保被引用的对象可用 （没有在析构，同时应该支持 weak 引用）
    bool deallocating;
    if (!referent->ISA()->hasCustomRR())
    {
        deallocating = referent->rootIsDeallocating();
    }
    else
    {
        BOOL (*allowsWeakReference)(objc_object *, SEL) = (BOOL(*)(objc_object *, SEL))object_getMethodImplementation((id)referent, SEL_allowsWeakReference);
        if ((IMP)allowsWeakReference == _objc_msgForward)
        {
            return nil;
        }
        deallocating = ! (*allowsWeakReference)(referent, SEL_allowsWeakReference);
    }

    if (deallocating)
    {
        if (crashIfDeallocating)
        {
            _objc_fatal("Cannot form weak reference to instance (%p) of "
                        "class %s. It is possible that this object was "
                        "over-released, or is in the process of deallocation.",
                        (void*)referent, object_getClassName((id)referent));
        }
        else
        {
            return nil;
        }
    }

    // now remember it and where it is being stored
    // 在 weak_table 中找到 referent 对应的 weak_entry
    // 并将 referrer 加入到 weak_entry 中
    weak_entry_t *entry;
    // 如果能找到 weak_entry,则讲 referrer 插入到 weak_entry 中
    if ((entry = weak_entry_for_referent(weak_table, referent)))
    {
        append_referrer(entry, referrer);   // 将 referrer 插入到 weak_entry_t 的引用数组中
    } 
    else
    {   // 如果找不到，就新建一个
        weak_entry_t new_entry(referent, referrer);
        weak_grow_maybe(weak_table);    // 判断是否需要扩容
        weak_entry_insert(weak_table, &new_entry);
    }

    // Do not set *referrer. objc_storeWeak() requires that the 
    // value not change.

    return referent_id;
}


#if DEBUG
bool
weak_is_registered_no_lock(weak_table_t *weak_table, id referent_id) 
{
    return weak_entry_for_referent(weak_table, (objc_object *)referent_id);
}
#endif


/** 
 * Called by dealloc; nils out all weak pointers that point to the 
 * provided object so that they can no longer be used.
 * 
 * @param weak_table 
 * @param referent The object being deallocated. 
 */
void 
weak_clear_no_lock(weak_table_t *weak_table, id referent_id) 
{
    objc_object *referent = (objc_object *)referent_id;

    weak_entry_t *entry = weak_entry_for_referent(weak_table, referent);    // 找到 referent 在 weak_table 中对应的 weak_entry_t
    if (entry == nil) {
        /// XXX shouldn't happen, but does with mismatched CF/objc
        //printf("XXX no entry for clear deallocating %p\n", referent);
        return;
    }

    // zero out references
    weak_referrer_t *referrers;
    size_t count;
    
    // 找出 weak 引用 referent 的 weak 指针地址数组以及数组长度
    if (entry->out_of_line()) {
        referrers = entry->referrers;
        count = TABLE_SIZE(entry);
    } 
    else {
        referrers = entry->inline_referrers;
        count = WEAK_INLINE_COUNT;
    }
    
    for (size_t i = 0; i < count; ++i) {
        objc_object **referrer = referrers[i];  // 取出每个 weak ptr 的地址
        if (referrer) {
            // 如果 referrer 确实 weak 引用了 referent
            // 则将 weak ptr 设置为 nil，这也就是为什么 weak 指针会自动设置为 nil 的原因
            if (*referrer == referent) {
                *referrer = nil;
            }
            else if (*referrer) {
                _objc_inform("__weak variable at %p holds %p instead of %p. "
                             "This is probably incorrect use of "
                             "objc_storeWeak() and objc_loadWeak(). "
                             "Break on objc_weak_error to debug.\n", 
                             referrer, (void*)*referrer, (void*)referent);
                objc_weak_error();
            }
        }
    }
    
    weak_entry_remove(weak_table, entry); // 释放 weak_entry_t
}

