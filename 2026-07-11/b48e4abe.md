# ✨ Feature 分析 - b48e4abe

## 基本信息

| 项目 | 内容 |
|------|------|
| **提交** | [b48e4abe](https://github.com/redis/redis/commit/b48e4abe) |
| **作者** | Mincho Paskalev |
| **日期** | 2026-07-09T04:55:40Z |
| **类型** | FEATURE |
| **统计** | +1101 -24 (10 个文件) |

## 提交消息

```
Add LMOVEM/BLMOVEM commands (#15405)
```

*无详细描述*

## 功能概述

新增 `LMOVEM` 和 `BLMOVEM` 命令，提供列表（List）数据结构的**多元素批量移动**能力。

### 现有命令对比

| 命令 | 功能 | 单次移动元素数 |
|------|------|----------------|
| `LMOVE` | 从一个列表弹出并推入另一个列表 | 1 个 |
| `BLMOVE` | 阻塞版 LMOVE | 1 个 |
| `LMOVEM` | **批量**从一个列表弹出并推入另一个列表 | **N 个** |
| `BLMOVEM` | **阻塞版**批量移动 | **N 个** |

### 使用场景

- 批量转移队列中的多个任务
- 高效的列表数据迁移
- 减少多次 `LMOVE` 的往返开销

## 文件变更

- `src/blocked.c` (modified, +63/-22)
- `src/cluster.c` (modified, +1/-0)
- `src/commands.def` (modified, +119/-0)
- `src/commands/blmovem.json` (added, +159/-0)
- `src/commands/lmovem.json` (added, +154/-0)
- `src/server.c` (modified, +4/-0)
- `src/server.h` (modified, +17/-1)
- `src/t_list.c` (modified, +284/-0)
- `tests/unit/moduleapi/blockonkeys.tcl` (modified, +51/-1)
- `tests/unit/type/list-4.tcl` (added, +249/-0)

## 代码变更分析


#### `src/blocked.c`

```diff
@@ -183,6 +183,7 @@ void queueClientForReprocessing(client *c) {
  * of operation the client is blocking for. */
 void unblockClient(client *c, int queue_for_reprocessing) {
     if (c->bstate.btype == BLOCKED_LIST ||
+        c->bstate.btype == BLOCKED_LIST_NONEMPTY ||
         c->bstate.btype == BLOCKED_ZSET ||
         c->bstate.btype == BLOCKED_STREAM) {
         unblockClientWaitingData(c);
@@ -222,6 +223,7 @@ int blockedClientMayTimeout(client *c) {
     }
 
     if (c->bstate.btype == BLOCKED_LIST ||
+        c->bstate.btype == BLOCKED_LIST_NONEMPTY ||
         c->bstate.btype == BLOCKED_ZSET ||
         c->bstate.btype == BLOCKED_STREAM ||
         c->bstate.btype == BLOCKED_WAIT ||
@@ -243,6 +245,7 @@ void replyToBlockedClientTimedOut(client *c) {
         else
             addReply(c, shared.ok); /* No reason lazy-free to fail */
     } else if (c->bstate.btype == BLOCKED_LIST ||
+        c->bstate.btype == BLOCKED_LIST_NONEMPTY ||
         c->bstate.btype == BLOCKED_ZSET ||
         c->bstate.btype == BLOCKED_STREAM) {
         addReplyNullArray(c);
@@ -474,28 +477,45 @@ static blocking_type getBlockedTypeByType(int type) {
     }
 }
 
-/* If the specified key has clients blocked waiting for list pushes, this
- * function will put the key reference into the server.ready_keys list.
- * Note that db->ready_keys is a hash table that allows us to avoid putting
- * the same key again and again in the list in case of multiple pushes
- * made by a script or in the context of MULTI/EXEC.
+/* Core of the signalKeyAsReady*() family. 'btype' is the kind of blockers this
+ * signal should serve:
  *
- * The list will be finally processed by handleClientsBlockedOnKeys() */
-static void signalKeyAsReadyLogic(redisDb *db, robj *key, int type, int deleted) {
+ *   BLOCKED_LIST / BLOCKED_ZSET / BLOCKED_STREAM
+ *       The key became available (created/loaded/explicit ready). Serves the
+ *       matching native blockers and module clients. A BLOCKED_LIST signal also
+ * 
```

#### `src/cluster.c`

```diff
@@ -1510,6 +1510,7 @@ int clusterRedirectBlockedClientIfNeeded(client *c) {
     clusterNode *myself = getMyClusterNode();
     if (c->flags & CLIENT_BLOCKED &&
         (c->bstate.btype == BLOCKED_LIST ||
+         c->bstate.btype == BLOCKED_LIST_NONEMPTY ||
          c->bstate.btype == BLOCKED_ZSET ||
          c->bstate.btype == BLOCKED_STREAM ||
          c->bstate.btype == BLOCKED_MODULE))
```

#### `src/commands.def`

```diff
@@ -4989,6 +4989,65 @@ struct COMMAND_ARG BLMOVE_Args[] = {
 {MAKE_ARG("timeout",ARG_TYPE_DOUBLE,-1,NULL,NULL,NULL,CMD_ARG_NONE,0,NULL)},
 };
 
+/********** BLMOVEM ********************/
+
+#ifndef SKIP_CMD_HISTORY_TABLE
+/* BLMOVEM history */
+#define BLMOVEM_History NULL
+#endif
+
+#ifndef SKIP_CMD_TIPS_TABLE
+/* BLMOVEM tips */
+#define BLMOVEM_Tips NULL
+#endif
+
+#ifndef SKIP_CMD_KEY_SPECS_TABLE
+/* BLMOVEM key specs */
+keySpec BLMOVEM_Keyspecs[2] = {
+{NULL,CMD_KEY_RW|CMD_KEY_ACCESS|CMD_KEY_DELETE,KSPEC_BS_INDEX,.bs.index={1},KSPEC_FK_RANGE,.fk.range={0,1,0}},{NULL,CMD_KEY_RW|CMD_KEY_INSERT,KSPEC_BS_INDEX,.bs.index={2},KSPEC_FK_RANGE,.fk.range={0,1,0}}
+};
+#endif
+
+/* BLMOVEM wherefrom argument table */
+struct COMMAND_ARG BLMOVEM_wherefrom_Subargs[] = {
+{MAKE_ARG("left",ARG_TYPE_PURE_TOKEN,-1,"LEFT",NULL,NULL,CMD_ARG_NONE,0,NULL)},
+{MAKE_ARG("right",ARG_TYPE_PURE_TOKEN,-1,"RIGHT",NULL,NULL,CMD_ARG_NONE,0,NULL)},
+};
+
+/* BLMOVEM whereto argument table */
+struct COMMAND_ARG BLMOVEM_whereto_Subargs[] = {
+{MAKE_ARG("left",ARG_TYPE_PURE_TOKEN,-1,"LEFT",NULL,NULL,CMD_ARG_NONE,0,NULL)},
+{MAKE_ARG("right",ARG_TYPE_PURE_TOKEN,-1,"RIGHT",NULL,NULL,CMD_ARG_NONE,0,NULL)},
+};
+
+/* BLMOVEM how_many selector argument table */
+struct COMMAND_ARG BLMOVEM_how_many_selector_Subargs[] = {
+{MAKE_ARG("count",ARG_TYPE_INTEGER,-1,"COUNT",NULL,NULL,CMD_ARG_NONE,0,NULL)},
+{MAKE_ARG("exactly",ARG_TYPE_INTEGER,-1,"EXACTLY",NULL,NULL,CMD_ARG_NONE,0,NULL)},
+};
+
+/* BLMOVEM how_many ordering argument table */
+struct COMMAND_ARG BLMOVEM_how_many_ordering_Subargs[] = {
+{MAKE_ARG("obo",ARG_TYPE_PURE_TOKEN,-1,"OBO",NULL,NULL,CMD_ARG_NONE,0,NULL)},
+{MAKE_ARG("bulk",ARG_TYPE_PURE_TOKEN,-1,"BULK",NULL,NULL,CMD_ARG_NONE,0,NULL)},
+};
+
+/* BLMOVEM how_many argument table */
+struct COMMAND_ARG BLMOVEM_how_many_Subargs[] = {
+{MAKE_ARG("selector",ARG_TYPE_ONEOF,-1,NULL,NULL,NULL,CMD_ARG_NONE,2,NULL),.subargs=BLMOVEM_how_many_selector_Subargs},
+{MAKE_ARG("ordering",ARG_TYPE_ONEO
```

#### `src/commands/blmovem.json`

```diff
@@ -0,0 +1,159 @@
+{
+    "BLMOVEM": {
+        "summary": "Moves up to (or exactly) a number of elements from one list to another and returns them. Blocks until the elements are available otherwise. Deletes the source list if it becomes empty.",
+        "complexity": "O(N) where N is the number of elements moved.",
+        "group": "list",
+        "since": "8.10.0",
+        "arity": -6,
+        "function": "blmovemCommand",
+        "command_flags": [
+            "WRITE",
+            "DENYOOM",
+            "BLOCKING"
+        ],
+        "acl_categories": [
+            "LIST"
+        ],
+        "key_specs": [
+            {
+                "flags": [
+                    "RW",
+                    "ACCESS",
+                    "DELETE"
+                ],
+                "begin_search": {
+                    "index": {
+                        "pos": 1
+                    }
+                },
+                "find_keys": {
+                    "range": {
+                        "lastkey": 0,
+                        "step": 1,
+                        "limit": 0
+                    }
+                }
+            },
+            {
+                "flags": [
+                    "RW",
+                    "INSERT"
+                ],
+                "begin_search": {
+                    "index": {
+                        "pos": 2
+                    }
+                },
+                "find_keys": {
+                    "range": {
+                        "lastkey": 0,
+                        "step": 1,
+                        "limit": 0
+                    }
+                }
+            }
+        ],
+        "reply_schema": {
+            "oneOf": [
+                {
+                    "description": "Operation timed-out.",
+                    "type": "null"
+                },
+                {
+                    "description": "The moved elements, in destination order.",
+                    "type": "array",
+          
```

#### `src/commands/lmovem.json`

```diff
@@ -0,0 +1,154 @@
+{
+    "LMOVEM": {
+        "summary": "Moves up to (or exactly) a number of elements from one list to another and returns them. Deletes the source list if it becomes empty.",
+        "complexity": "O(N) where N is the number of elements moved.",
+        "group": "list",
+        "since": "8.10.0",
+        "arity": -5,
+        "function": "lmovemCommand",
+        "command_flags": [
+            "WRITE",
+            "DENYOOM"
+        ],
+        "acl_categories": [
+            "LIST"
+        ],
+        "key_specs": [
+            {
+                "flags": [
+                    "RW",
+                    "ACCESS",
+                    "DELETE"
+                ],
+                "begin_search": {
+                    "index": {
+                        "pos": 1
+                    }
+                },
+                "find_keys": {
+                    "range": {
+                        "lastkey": 0,
+                        "step": 1,
+                        "limit": 0
+                    }
+                }
+            },
+            {
+                "flags": [
+                    "RW",
+                    "INSERT"
+                ],
+                "begin_search": {
+                    "index": {
+                        "pos": 2
+                    }
+                },
+                "find_keys": {
+                    "range": {
+                        "lastkey": 0,
+                        "step": 1,
+                        "limit": 0
+                    }
+                }
+            }
+        ],
+        "reply_schema": {
+            "oneOf": [
+                {
+                    "description": "Not enough elements to satisfy EXACTLY; nothing moved.",
+                    "type": "null"
+                },
+                {
+                    "description": "The moved elements, in destination order.",
+                    "type": "array",
+                    "items": {
+                      
```

#### `src/server.c`

```diff
@@ -2288,6 +2288,10 @@ void createSharedObjects(void) {
     shared.rpoplpush = createStringObject("RPOPLPUSH",9);
     shared.lmove = createStringObject("LMOVE",5);
     shared.blmove = createStringObject("BLMOVE",6);
+    shared.lmovem = createStringObject("LMOVEM",6);
+    shared.exactly = createStringObject("EXACTLY",7);
+    shared.obo = createStringObject("OBO",3);
+    shared.bulk = createStringObject("BULK",4);
     shared.zpopmin = createStringObject("ZPOPMIN",7);
     shared.zpopmax = createStringObject("ZPOPMAX",7);
     shared.multi = createStringObject("MULTI",5);
```

#### `src/server.h`

```diff
@@ -495,6 +495,12 @@ typedef enum blocking_type {
     BLOCKED_POSTPONE_TRIM, /* Master client is blocked due to an active trim job. */
     BLOCKED_SHUTDOWN, /* SHUTDOWN. */
     BLOCKED_LAZYFREE, /* LAZYFREE */
+    BLOCKED_LIST_NONEMPTY, /* Blocked waiting for an already-existing list to
+                            * grow enough (BLMOVEM EXACTLY). Woken by list
+                            * creation (like BLOCKED_LIST) and by writes that
+                            * grow a pre-existing list, but NOT limited to key
+                            * availability. Unlike BLOCKED_LIST, module clients
+                            * are not woken by the "list grew" signal. */
     BLOCKED_NUM,      /* Number of blocked states. */
     BLOCKED_END       /* End of enumeration */
 } blocking_type;
@@ -1323,6 +1329,12 @@ typedef struct blockingState {
 typedef struct readyList {
     redisDb *db;
     robj *key;
+    int wake_modules;           /* Whether module-blocked clients on this key
+                                 * should be served. Set to 0 by signals coming
+                                 * from BLOCKED_LIST_NONEMPTY (plain writes to a
+                                 * pre-existing list), so module clients keep
+                                 * being woken only by RM_SignalKeyAsReady or
+                                 * key (re)creation. */
 } readyList;
 
 /* List of pending commands. */
@@ -1735,7 +1747,8 @@ struct sharedObjectsStruct {
     *masterdownerr, *roslaveerr, *execaborterr, *noautherr, *noreplicaserr,
     *busykeyerr, *oomerr, *plus, *messagebulk, *pmessagebulk, *subscribebulk,
     *unsubscribebulk, *psubscribebulk, *punsubscribebulk, *del, *unlink,
-    *rpop, *lpop, *lpush, *rpoplpush, *lmove, *blmove, *zpopmin, *zpopmax,
+    *rpop, *lpop, *lpush, *rpoplpush, *lmove, *blmove, *lmovem, *exactly,
+    *obo, *bulk, *zpopmin, *zpopmax,
     *emptyscan, *multi, *exec, *left, *right, *hset, *srem, *xgroup, *xclaim, *xack,
     *script, *rep
```

#### `src/t_list.c`

```diff
@@ -489,6 +489,7 @@ void pushGenericCommand(client *c, int where, int xx) {
 
     kvobj *lobj = lookupKeyWriteWithLink(c->db, c->argv[1], &link);
     if (checkType(c,lobj,OBJ_LIST)) return;
+    int existed = (lobj != NULL);
     if (!lobj) {
         if (xx) {
             addReply(c, shared.czero);
@@ -512,6 +513,12 @@ void pushGenericCommand(client *c, int where, int xx) {
 
     char *event = (where == LIST_HEAD) ? "lpush" : "rpush";
     keyModified(c,c->db,c->argv[1],lobj,1);
+    /* Wake clients blocked on this key. dbAdd() already signals a freshly
+     * created key, but a push to a pre-existing list must signal too, so that
+     * clients blocked on an existing key (e.g. BLMOVEM EXACTLY waiting for more
+     * elements) are re-processed. */
+    if (existed)
+        signalKeyAsReadyNonEmptyList(c->db, c->argv[1]);
     notifyKeyspaceEvent(NOTIFY_LIST,event,c->argv[1],c->db->id);
     updateKeysizesHist(c->db, OBJ_LIST, llen - (c->argc - 2), llen);
     if (server.memory_tracking_enabled)
@@ -586,6 +593,9 @@ void linsertCommand(client *c) {
 
     if (inserted) {
         keyModified(c,c->db,c->argv[1],subject,1);
+        /* LINSERT only operates on a pre-existing list, so this is always a
+         * write to an existing key (module clients are not woken). */
+        signalKeyAsReadyNonEmptyList(c->db, c->argv[1]);
         notifyKeyspaceEvent(NOTIFY_LIST,"linsert",
                             c->argv[1],c->db->id);
         server.dirty++;
@@ -1163,6 +1173,7 @@ void lremCommand(client *c) {
 void lmoveHandlePush(client *c, robj *dstkey, robj *dstobj, robj *value,
                      int where) {
     size_t oldsize = 0;
+    int existed = (dstobj != NULL);
     /* Create the list if the key does not exist */
     if (!dstobj) {
         dstobj = createListListpackObject();
@@ -1175,6 +1186,10 @@ void lmoveHandlePush(client *c, robj *dstkey, robj *dstobj, robj *value,
     if (server.memory_tracking_enabled)
         updateSlotAllocSize(c->db, g
```

#### `tests/unit/moduleapi/blockonkeys.tcl`

```diff
@@ -311,7 +311,57 @@ start_server {tags {"modules external:skip"}} {
         assert_equal {gg ff ee dd cc} [$rd read]
         $rd close
     }
-    
+
+    test {LINSERT does not wake a module blocked on a list key} {
+        r del k
+        r rpush k a b
+        # Module client blocks to pop 5 elements from the (existing) list.
+        set rd [redis_deferring_client]
+        $rd blockonkeys.blpopn k 5
+        wait_for_blocked_clients_count 1
+        # Plain writes to a pre-existing list must NOT wake a module client, even
+        # once the list is long enough to satisfy it.
+        r linsert k before a x  ;# 3 elements
+        r linsert k before a y  ;# 4 elements
+        r linsert k before a z  ;# 5 elements -> enough, but LINSERT doesn't signal
+        assert_equal 1 [s blocked_clients]
+        # Only an explicit RM_SignalKeyAsReady wakes it.
+        r blockonkeys.lpush_unblock k q
+        assert_equal 5 [llength [$rd read]]
+        assert_equal 1 [r llen k]
+        $rd close
+    }
+
+    test {BLMOVEM does not wake a module blocked on the destination list} {
+        r del src dst
+        r rpush dst a b        ;# destination pre-exists with 2 elements
+        r rpush src c d e f
+        set rd [redis_deferring_client]
+        $rd blockonkeys.blpopn dst 5
+        wait_for_blocked_clients_count 1
+        # BLMOVEM grows the pre-existing destination to 5, but as a plain list
+        # write it must NOT wake the blocked module client.
+        assert_equal {c d e} [r blmovem src dst left right 0 count 3 bulk]
+        assert_equal 1 [s blocked_clients]
+        # An explicit module signal still unblocks it.
+        r blockonkeys.lpush_unblock dst z
+        assert_equal 5 [llength [$rd read]]
+        $rd close
+    }
+
+    test {BLMOVEM wakes a module blocked on a non-existent destination list} {
+        r del src dst
+        r rpush src a b c
+        set rd [redis_deferring_client]
+        $rd blockonkeys.popall dst   ;# dst does
```

#### `tests/unit/type/list-4.tcl`

```diff
@@ -0,0 +1,249 @@
+start_server {
+    tags {"list"}
+    overrides {
+        "list-max-ziplist-size" -1
+    }
+} {
+    array set largevalue [generate_largevalue_test_array]
+
+    proc create_listpack {key entries} {
+        r del $key
+        foreach entry $entries { r rpush $key $entry }
+        assert_encoding listpack $key
+    }
+
+    proc create_quicklist {key entries} {
+        r del $key
+        foreach entry $entries { r rpush $key $entry }
+        assert_encoding quicklist $key
+    }
+
+foreach {type large} [array get largevalue] {
+    test "LMOVEM single element, array reply (like LMOVE) - $type" {
+        r del src{t} dst{t}
+        create_$type src{t} "a b c $large"
+        assert_equal {a} [r lmovem src{t} dst{t} left right]
+        assert_equal {a} [r lrange dst{t} 0 -1]
+        assert_equal "b c $large" [r lrange src{t} 0 -1]
+    }
+
+    test "LMOVEM COUNT left pop, OBO vs BULK ordering - $type" {
+        r del src{t} dst{t}
+        create_$type src{t} "1 2 3 4 5 $large"
+        # OBO: each element pushed as popped -> block order reversed at head.
+        assert_equal {3 2 1} [r lmovem src{t} dst{t} left left count 3 obo]
+        assert_equal {3 2 1} [r lrange dst{t} 0 -1]
+        assert_equal "4 5 $large" [r lrange src{t} 0 -1]
+
+        r del src{t} dst{t}
+        create_$type src{t} "1 2 3 4 5 $large"
+        # BULK: source relative order preserved at head.
+        assert_equal {1 2 3} [r lmovem src{t} dst{t} left left count 3 bulk]
+        assert_equal {1 2 3} [r lrange dst{t} 0 -1]
+        assert_equal "4 5 $large" [r lrange src{t} 0 -1]
+    }
+
+    test "LMOVEM COUNT right pop, OBO vs BULK ordering - $type" {
+        r del src{t} dst{t}
+        create_$type src{t} "$large 1 2 3 4 5"
+        # pop order from the tail is 5 4 3.
+        assert_equal {5 4 3} [r lmovem src{t} dst{t} right right count 3 obo]
+        assert_equal {5 4 3} [r lrange dst{t} 0 -1]
+        assert_equal "$large 1 2" [r lrange src{t} 0
```


## 使用示例

```bash
# 从 source_list 批量移动 5 个元素到 dest_list
LMOVEM source_list dest_list LEFT RIGHT 5

# 阻塞版：等待 source_list 有元素后批量移动 10 个
BLMOVEM source_list dest_list LEFT RIGHT 10 0
```

### 参数说明

```
LMOVEM source destination LEFT|RIGHT LEFT|RIGHT count
BLMOVEM source destination LEFT|RIGHT LEFT|RIGHT count timeout
```

- `source` / `destination`: 源列表和目标列表
- 第一个 `LEFT|RIGHT`: 从源列表的哪一端弹出
- 第二个 `LEFT|RIGHT`: 推入目标列表的哪一端
- `count`: 批量移动的元素数量
- `timeout`: BLMOVEM 的阻塞超时时间（秒）

## 影响评估

| 维度 | 评估 |
|------|------|
| **影响范围** | 使用 List 结构的 Redis 用户 |
| **向后兼容** | 是（新增命令，不影响现有命令） |
| **客户端支持** | 需要客户端库更新以识别新命令 |
| **性能提升** | 减少多次单元素移动的 RTT 开销 |

---

*文档自动生成于 2026-07-11*
