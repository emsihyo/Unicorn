//
//  User.m
//  Unicorn
//
//  Created by emsihyo on 2018/5/3.
//  Copyright © 2018 emsihyo. All rights reserved.
//

#import "User.h"

@implementation User

+ (NSDictionary * _Nonnull)uni_keyPaths{
    return @{
             @"id":@"id",
             @"nickname":@"nickname",
             @"age":@"age"
             };
}

+ (NSString * _Nonnull)uni_primaryKey {
    return @"id";
}

+ (NSArray * _Nonnull)uni_columns{
    return @[@"id",@"nickname",@"age"];
}

@end