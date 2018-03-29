//
//  UniDB.m
//  Unicorn
//



#import "UniDB.h"

NSString *const UniDBErrorDomain = @"UniDBErrorDomain";

@interface UniStmt : NSObject

@property (nonatomic, assign) sqlite3_stmt *stmt;
@property (nonatomic, copy) NSString *sql;

@end

@implementation UniStmt

- (void)dealloc {
    if (self.stmt) sqlite3_finalize(self.stmt);
}

@end

@interface UniDB ()

@property (nonatomic, assign) sqlite3 *db;
@property (nonatomic, assign) UInt64 transactionReferenceCount;
@property (nonatomic, strong) NSMutableDictionary *stmts;

@end

@implementation UniDB

- (void)dealloc {
    [self close];
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.transactionReferenceCount = 0;
    self.stmts = [NSMutableDictionary dictionary];
    return self;
}

#pragma mark--
#pragma mark-- open and close

- (BOOL)open:(NSString *)file error:(NSError **)error {
    [self close];
    sqlite3 *db;
    if (sqlite3_open([file cStringUsingEncoding:NSUTF8StringEncoding], &db) != SQLITE_OK) {
        if (error) *error = [self error];
        return NO;
    }
    self.db = db;
    return YES;
}

- (BOOL)close {
    if (self.db) {
        [self.stmts removeAllObjects];
        if (sqlite3_close(self.db) != SQLITE_OK) return NO;
        self.db = nil;
    }
    return YES;
}

#pragma mark--
#pragma mark-- stmt

- (sqlite3_stmt *)stmtForSql:(NSString *)sql error:(NSError **)error {
    UniStmt *s = self.stmts[sql];
    if (!s) {
        sqlite3_stmt *stmt;
        if (sqlite3_prepare_v2(self.db, [sql UTF8String], -1, &stmt, 0) != SQLITE_OK) {
            sqlite3_finalize(stmt);
            if (error) *error = [self error];
            return NULL;
        }
        s = [[UniStmt alloc] init];
        s.stmt = stmt;
        s.sql = sql;
        self.stmts[sql] = s;
    }
    sqlite3_reset(s.stmt);
    sqlite3_clear_bindings(s.stmt);
    return s.stmt;
}

- (void)removeStmtForSql:(NSString *)sql {
    [self.stmts removeObjectForKey:sql];
}

- (void)removeAllStmt {
    [self.stmts removeAllObjects];
}

#pragma mark--
#pragma mark-- query

- (NSArray *)executeQuery:(NSString *)sql arguments:(NSArray *)arguments error:(NSError **)error {
    return [self executeQuery:sql stmtBlock:^(sqlite3_stmt *stmt, int idx) {
        [self _bindObject:arguments[idx - 1] toColumn:idx inStatement:stmt];
    } error:error];
}

- (NSArray *)executeQuery:(NSString *)sql stmtBlock:(void (^)(sqlite3_stmt *stmt, int idx))stmtBlock error:(NSError **)error {
    __block NSMutableArray *array = [NSMutableArray array];
    [self executeQuery:sql stmtBlock:stmtBlock resultBlock:^(sqlite3_stmt *stmt, bool *stop) {
        int count = sqlite3_data_count(stmt);
        NSDictionary *dictionary = [self _dictionaryInStmt:stmt count:count];
        if (dictionary.count > 0) [array addObject:dictionary];
    } error:error];
    return array;
}

- (BOOL)executeQuery:(NSString *)sql arguments:(NSArray *)arguments resultBlock:(void (^)(sqlite3_stmt *stmt, bool *stop))resultBlock error:(NSError **)error {
    return [self executeQuery:sql stmtBlock:^(sqlite3_stmt *stmt, int idx) {
        [self _bindObject:arguments[idx-1] toColumn:idx inStatement:stmt];
    } resultBlock:resultBlock error:error];
}

- (BOOL)executeQuery:(NSString *)sql stmtBlock:(void (^)(sqlite3_stmt *stmt, int idx))stmtBlock resultBlock:(void (^)(sqlite3_stmt *stmt, bool *stop))resultBlock error:(NSError **)error {
    NSParameterAssert(stmtBlock);
    NSParameterAssert(resultBlock);
    sqlite3_stmt *stmt = [self stmtForSql:sql error:error];
    if (!stmt) return NO;
    int count = sqlite3_bind_parameter_count(stmt);
    for (int i = 0; i < count; i++) {
        stmtBlock(stmt, i + 1);
    }
    bool stop = NO;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        resultBlock(stmt, &stop);
        if (stop) break;
    }
    return YES;
}

#pragma mark--
#pragma mark-- update

- (BOOL)executeUpdate:(NSString *)sql arguments:(NSArray *)arguments error:(NSError **)error {
    return [self executeUpdate:sql stmtBlock:^(sqlite3_stmt *stmt, int idx) {
        [self _bindObject:arguments[idx-1] toColumn:idx inStatement:stmt];
    } error:error];
}

- (BOOL)executeUpdate:(NSString *)sql stmtBlock:(void (^)(sqlite3_stmt *stmt, int idx))stmtBlock error:(NSError **)error {
    sqlite3_stmt *stmt = [self stmtForSql:sql error:error];
    if (!stmt) {
        if (error) *error = [self error];
        return NO;
    }
    int count = sqlite3_bind_parameter_count(stmt);
    for (int i = 0; i < count; i++) {
        stmtBlock(stmt, i + 1);
    }
    if (sqlite3_step(stmt) != SQLITE_DONE) {
        if (error) *error = [self error];
        return NO;
    }
    return YES;
}

#pragma mark--
#pragma mark--transaction

- (BOOL)beginTransaction {
    BOOL res=YES;
    self.transactionReferenceCount++;
    if (self.transactionReferenceCount == 1) res=[self executeUpdate:@"BEGIN" arguments:nil error:nil];
    return res;
}

- (BOOL)commit {
    BOOL res=YES;
    if (self.transactionReferenceCount > 0) {
        self.transactionReferenceCount--;
        if (self.transactionReferenceCount == 0) res= [self executeUpdate:@"COMMIT" arguments:nil error:nil];
    }
    return res;
}

#pragma mark--
#pragma mark-- bind object to column

- (int)_bindObject:(id)obj toColumn:(int)idx inStatement:(sqlite3_stmt *)stmt {
    int result = SQLITE_OK;
    if ((!obj) || obj == (id)kCFNull) {
        result = sqlite3_bind_null(stmt, idx);
    } else if ([obj isKindOfClass:NSNumber.class]) {
        if (strcmp([obj objCType], @encode(char)) == 0) {
            result = sqlite3_bind_int(stmt, idx, [obj charValue]);
        } else if (strcmp([obj objCType], @encode(unsigned char)) == 0) {
            result = sqlite3_bind_int(stmt, idx, [obj unsignedCharValue]);
        } else if (strcmp([obj objCType], @encode(short)) == 0) {
            result = sqlite3_bind_int(stmt, idx, [obj shortValue]);
        } else if (strcmp([obj objCType], @encode(unsigned short)) == 0) {
            result = sqlite3_bind_int(stmt, idx, [obj unsignedShortValue]);
        } else if (strcmp([obj objCType], @encode(int)) == 0) {
            result = sqlite3_bind_int(stmt, idx, [obj intValue]);
        } else if (strcmp([obj objCType], @encode(unsigned int)) == 0) {
            result = sqlite3_bind_int64(stmt, idx, (long long)[obj unsignedIntValue]);
        } else if (strcmp([obj objCType], @encode(long)) == 0) {
            result = sqlite3_bind_int64(stmt, idx, [obj longValue]);
        } else if (strcmp([obj objCType], @encode(unsigned long)) == 0) {
            result = sqlite3_bind_int64(stmt, idx, (long long)[obj unsignedLongValue]);
        } else if (strcmp([obj objCType], @encode(long long)) == 0) {
            result = sqlite3_bind_int64(stmt, idx, [obj longLongValue]);
        } else if (strcmp([obj objCType], @encode(unsigned long long)) == 0) {
            result = sqlite3_bind_int64(stmt, idx, (long long)[obj unsignedLongLongValue]);
        } else if (strcmp([obj objCType], @encode(float)) == 0) {
            result = sqlite3_bind_double(stmt, idx, [obj floatValue]);
        } else if (strcmp([obj objCType], @encode(double)) == 0) {
            result = sqlite3_bind_double(stmt, idx, [obj doubleValue]);
        } else if (strcmp([obj objCType], @encode(bool)) == 0) {
            result = sqlite3_bind_int(stmt, idx, ([obj boolValue] ? 1 : 0));
        } else {
            result = sqlite3_bind_text(stmt, idx, [[obj description] UTF8String], -1, SQLITE_STATIC);
        }
    } else if ([obj isKindOfClass:NSData.class]) {
        const void *bytes = [obj bytes];
        if (bytes) {
            result = sqlite3_bind_blob(stmt, idx, bytes, (int)[obj length], SQLITE_STATIC);
        } else {
            result = sqlite3_bind_null(stmt, idx);
        }
    } else {
        result = sqlite3_bind_text(stmt, idx, [[obj description] UTF8String], -1, SQLITE_STATIC);
    }
    return result;
}

#pragma mark--
#pragma mark-- getter

- (NSDictionary *)_dictionaryInStmt:(sqlite3_stmt *)stmt count:(int)count {
    NSMutableDictionary *set = [NSMutableDictionary dictionary];
    for (int idx = 0; idx < count; idx++) {
        NSString *columnName = [NSString stringWithUTF8String:sqlite3_column_name(stmt, idx)];
        int type = sqlite3_column_type(stmt, idx);
        id value = nil;
        switch (type) {
            case SQLITE_INTEGER: value = @(sqlite3_column_int64(stmt, idx)); break;
            case SQLITE_FLOAT: value = @(sqlite3_column_double(stmt, idx)); break;
            case SQLITE_BLOB: {
                int bytes = sqlite3_column_bytes(stmt, idx);
                value = [NSData dataWithBytes:sqlite3_column_blob(stmt, idx) length:bytes];
            } break;
            case SQLITE_NULL: break;
            default: value = [[NSString alloc] initWithCString:(const char *)sqlite3_column_text(stmt, idx) encoding:NSUTF8StringEncoding]; break;
        }
        if (value && value != (id)kCFNull) set[columnName] = value;
    }
    return set;
}

- (NSError *)error {
    return [NSError errorWithDomain:NSStringFromClass(self.class) code:sqlite3_errcode(self.db) userInfo:@{NSLocalizedDescriptionKey:[[NSString alloc] initWithCString:sqlite3_errmsg(self.db) encoding:NSUTF8StringEncoding]}];
}

@end