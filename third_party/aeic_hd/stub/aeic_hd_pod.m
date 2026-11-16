// AI sketch HD on iPhone: always built with the pod. The codec itself is
// ios/lib/libaeic_hd.a, built by CI (tool/build_aeic_hd_ios.sh); without it,
// the app finds no aeic_hd_run and says AI sketch HD can't run here.
//
// The ~2 GB model pack can be downloaded again, so it is kept out of iCloud
// and device backups, as Apple asks of downloadable content.

#import <Foundation/Foundation.h>

__attribute__((visibility("default"), used))
int aeic_hd_exclude_from_backup(const char *path) {
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path];
        if (p == nil) return 0;
        NSURL *url = [NSURL fileURLWithPath:p];
        NSError *error = nil;
        return [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error] ? 1 : 0;
    }
}
