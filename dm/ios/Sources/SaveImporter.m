#import "SaveImporter.h"
#include <zlib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t rd16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1] << 8); }
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static BOOL safe_rel_path(NSString *raw, NSString **cleanOut) {
    NSString *s = [raw stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    while ([s hasPrefix:@"./"]) s = [s substringFromIndex:2];
    if (!s.length || [s hasPrefix:@"/"]) return NO;
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *p in parts) {
        if (!p.length || [p isEqualToString:@"."]) continue;
        if ([p isEqualToString:@".."]) return NO;
        [kept addObject:p];
    }
    if (!kept.count) return NO;
    if ([kept[0] isEqualToString:@"__MACOSX"] || [kept.lastObject isEqualToString:@".DS_Store"]) {
        *cleanOut = nil;
        return YES;
    }
    *cleanOut = [kept componentsJoinedByString:@"/"];
    return YES;
}

static BOOL inflate_entry(FILE *fp, uint64_t comp_off, uint32_t comp_sz, uint32_t uncomp_sz,
                          uint16_t method, uint32_t want_crc, const char *dst_path,
                          NSString **errOut) {
    if (fseeko(fp, (off_t)comp_off, SEEK_SET) != 0) {
        if (errOut) *errOut = @"Could not read compressed entry inside the zip archive.";
        return NO;
    }
    FILE *out = fopen(dst_path, "wb");
    if (!out) {
        if (errOut) *errOut = @"Could not create extracted file on device storage.";
        return NO;
    }

    uint8_t inbuf[32768];
    uint8_t outbuf[32768];
    uLong crc = crc32(0L, Z_NULL, 0);
    uint64_t total_out = 0;
    BOOL ok = YES;

    if (method == 0) {
        if (comp_sz != uncomp_sz) {
            if (errOut) *errOut = @"Corrupt stored zip entry (size mismatch).";
            ok = NO;
        }
        uint32_t left = comp_sz;
        while (ok && left > 0) {
            size_t chunk = left < sizeof(inbuf) ? left : sizeof(inbuf);
            if (fread(inbuf, 1, chunk, fp) != chunk) {
                if (errOut) *errOut = @"Unexpected end of zip file.";
                ok = NO; break;
            }
            if (fwrite(inbuf, 1, chunk, out) != chunk) {
                if (errOut) *errOut = @"Write error while extracting file.";
                ok = NO; break;
            }
            crc = crc32(crc, inbuf, (uInt)chunk);
            left -= (uint32_t)chunk;
            total_out += chunk;
        }
    } else if (method == 8) {
        z_stream zs;
        memset(&zs, 0, sizeof(zs));
        if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) {
            fclose(out);
            if (errOut) *errOut = @"zlib initialization failed.";
            return NO;
        }
        uint32_t left = comp_sz;
        int zret = Z_OK;
        while (ok && zret != Z_STREAM_END) {
            if (zs.avail_in == 0 && left > 0) {
                size_t chunk = left < sizeof(inbuf) ? left : sizeof(inbuf);
                if (fread(inbuf, 1, chunk, fp) != chunk) {
                    if (errOut) *errOut = @"Unexpected end of deflated zip data.";
                    ok = NO; break;
                }
                zs.next_in = inbuf;
                zs.avail_in = (uInt)chunk;
                left -= (uint32_t)chunk;
            }
            zs.next_out = outbuf;
            zs.avail_out = sizeof(outbuf);
            zret = inflate(&zs, Z_NO_FLUSH);
            if (zret != Z_OK && zret != Z_STREAM_END) {
                if (errOut) *errOut = @"Decompression failed (corrupt deflate stream).";
                ok = NO; break;
            }
            size_t have = sizeof(outbuf) - zs.avail_out;
            if (have > 0) {
                if (total_out + have > uncomp_sz || fwrite(outbuf, 1, have, out) != have) {
                    if (errOut) *errOut = @"Write error or size overflow while decompressing zip entry.";
                    ok = NO; break;
                }
                crc = crc32(crc, outbuf, (uInt)have);
                total_out += have;
            }
            if (zret != Z_STREAM_END && zs.avail_in == 0 && left == 0) {
                if (errOut) *errOut = @"Truncated zip entry.";
                ok = NO; break;
            }
        }
        inflateEnd(&zs);
    } else {
        if (errOut) *errOut = [NSString stringWithFormat:@"Unsupported zip compression method (%u). Use standard Deflate/Store zip.", method];
        ok = NO;
    }

    fclose(out);
    if (ok && (total_out != uncomp_sz || (uint32_t)crc != want_crc)) {
        if (errOut) *errOut = @"Zip CRC or size check failed (file may be corrupted).";
        ok = NO;
    }
    return ok;
}

static BOOL extract_zip_to_dir(NSURL *zipURL, NSString *stageDir, NSUInteger *fileCountOut, NSString **errOut) {
    FILE *fp = fopen(zipURL.fileSystemRepresentation, "rb");
    if (!fp) {
        if (errOut) *errOut = @"Could not open the selected .zip file.";
        return NO;
    }
    if (fseeko(fp, 0, SEEK_END) != 0) { fclose(fp); return NO; }
    off_t fsz = ftello(fp);
    if (fsz < 22 || fsz > (off_t)(512ull << 20)) {
        fclose(fp);
        if (errOut) *errOut = @"Invalid or oversized .zip file (limit 512 MB).";
        return NO;
    }

    uint64_t scan_len = (uint64_t)(fsz < 65557 ? fsz : 65557);
    uint8_t *tail = malloc((size_t)scan_len);
    if (!tail) { fclose(fp); return NO; }
    fseeko(fp, fsz - (off_t)scan_len, SEEK_SET);
    if (fread(tail, 1, (size_t)scan_len, fp) != scan_len) {
        free(tail); fclose(fp);
        if (errOut) *errOut = @"Could not read zip header.";
        return NO;
    }

    ssize_t eocd_pos = -1;
    for (ssize_t i = (ssize_t)scan_len - 22; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
            uint16_t cmt = rd16(tail + i + 20);
            if ((size_t)i + 22 + cmt == scan_len) { eocd_pos = i; break; }
        }
    }
    if (eocd_pos < 0) {
        free(tail); fclose(fp);
        if (errOut) *errOut = @"Not a valid .zip archive (End of Central Directory missing).";
        return NO;
    }
    uint16_t total_entries = rd16(tail + eocd_pos + 10);
    uint32_t cd_size = rd32(tail + eocd_pos + 12);
    uint32_t cd_off = rd32(tail + eocd_pos + 16);
    free(tail);

    if (total_entries == 0xFFFF || cd_off == 0xFFFFFFFFu || (uint64_t)cd_off + cd_size > (uint64_t)fsz) {
        fclose(fp);
        if (errOut) *errOut = @"ZIP64 or corrupted central directory is not supported.";
        return NO;
    }

    uint8_t *cd = malloc(cd_size ? cd_size : 1);
    if (!cd) { fclose(fp); return NO; }
    fseeko(fp, (off_t)cd_off, SEEK_SET);
    if (cd_size && fread(cd, 1, cd_size, fp) != cd_size) {
        free(cd); fclose(fp);
        if (errOut) *errOut = @"Could not read zip directory.";
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    uint32_t pos = 0;
    NSUInteger count = 0;
    uint64_t total_unpacked = 0;
    BOOL ok = YES;

    for (uint16_t idx = 0; idx < total_entries; idx++) {
        if ((uint64_t)pos + 46 > cd_size || rd32(cd + pos) != 0x02014b50u) {
            if (errOut) *errOut = @"Corrupt entry inside zip directory.";
            ok = NO; break;
        }
        uint16_t flags = rd16(cd + pos + 8);
        uint16_t method = rd16(cd + pos + 10);
        uint32_t crc = rd32(cd + pos + 16);
        uint32_t comp_sz = rd32(cd + pos + 20);
        uint32_t uncomp_sz = rd32(cd + pos + 24);
        uint16_t name_len = rd16(cd + pos + 28);
        uint16_t extra_len = rd16(cd + pos + 30);
        uint16_t cmt_len = rd16(cd + pos + 32);
        uint32_t ext_attr = rd32(cd + pos + 38);
        uint32_t lfh_off = rd32(cd + pos + 42);
        if ((uint64_t)pos + 46 + name_len + extra_len + cmt_len > cd_size) {
            if (errOut) *errOut = @"Truncated zip directory entry.";
            ok = NO; break;
        }
        BOOL hasNul = name_len > 0 && memchr(cd + pos + 46, '\0', name_len) != NULL;
        NSString *rawName = [[NSString alloc] initWithBytes:cd + pos + 46 length:name_len encoding:NSUTF8StringEncoding];
        if (!rawName) rawName = [[NSString alloc] initWithBytes:cd + pos + 46 length:name_len encoding:NSISOLatin1StringEncoding];
        pos += 46u + name_len + extra_len + cmt_len;

        if (hasNul) {
            if (errOut) *errOut = @"Unsafe file path inside zip archive.";
            ok = NO; break;
        }
        if (comp_sz == 0xFFFFFFFFu || uncomp_sz == 0xFFFFFFFFu || lfh_off == 0xFFFFFFFFu) {
            if (errOut) *errOut = @"ZIP64 entries are not supported.";
            ok = NO; break;
        }
        BOOL isDir = [rawName hasSuffix:@"/"] || [rawName hasSuffix:@"\\"];
        BOOL isSymlink = ((ext_attr >> 16) & 0170000u) == 0120000u;
        if (!rawName || isSymlink) continue;
        if (flags & 1) {
            if (errOut) *errOut = @"Encrypted zip files are not supported.";
            ok = NO; break;
        }

        NSString *rel = nil;
        if (!safe_rel_path(rawName, &rel)) {
            if (errOut) *errOut = @"Unsafe file path inside zip archive.";
            ok = NO; break;
        }
        if (!rel) continue;

        NSString *dst = [stageDir stringByAppendingPathComponent:rel];
        if (isDir) {
            [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }

        if (total_unpacked + uncomp_sz > (512ull << 20)) {
            if (errOut) *errOut = @"Unpacked zip size exceeds 512 MB limit.";
            ok = NO; break;
        }
        total_unpacked += uncomp_sz;

        uint8_t lfh[30];
        if ((uint64_t)lfh_off + 30 > (uint64_t)fsz || fseeko(fp, (off_t)lfh_off, SEEK_SET) != 0 || fread(lfh, 1, 30, fp) != 30 || rd32(lfh) != 0x04034b50u) {
            if (errOut) *errOut = @"Corrupt local file header in zip.";
            ok = NO; break;
        }
        uint16_t l_name = rd16(lfh + 26), l_extra = rd16(lfh + 28);
        uint64_t data_off = (uint64_t)lfh_off + 30 + l_name + l_extra;
        if (data_off + comp_sz > (uint64_t)fsz) {
            if (errOut) *errOut = @"Corrupt zip entry offset.";
            ok = NO; break;
        }

        NSError *de = nil;
        if (![fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&de]) {
            if (errOut) *errOut = de.localizedDescription ?: @"Failed to create destination folder.";
            ok = NO; break;
        }
        if (!inflate_entry(fp, data_off, comp_sz, uncomp_sz, method, crc, dst.fileSystemRepresentation, errOut)) {
            ok = NO; break;
        }
        count++;
    }

    free(cd);
    fclose(fp);
    if (ok && count == 0) {
        if (errOut) *errOut = @"The zip archive contained no files.";
        return NO;
    }
    if (fileCountOut) *fileCountOut = count;
    return ok;
}

static BOOL is_16hex(NSString *s) {
    if (s.length != 16) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    return [s rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static NSString *unwrap_single_root(NSString *root, BOOL modMode) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *cur = root;
    for (int depth = 0; depth < 3; depth++) {
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:cur error:nil];
        if (items.count != 1) break;
        NSString *name = items[0];
        NSString *child = [cur stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:child isDirectory:&isDir] || !isDir) break;
        BOOL unwrap = (depth == 0)
            || (modMode && [name caseInsensitiveCompare:@"romfs"] == NSOrderedSame)
            || (!modMode && ([name caseInsensitiveCompare:@"save"] == NSOrderedSame || is_16hex(name)));
        if (!unwrap) break;
        cur = child;
    }
    return cur;
}

static NSUInteger count_files_recursive(NSString *dir) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
    NSUInteger n = 0;
    for (NSString *rel in en) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:rel] isDirectory:&isDir] && !isDir) n++;
    }
    return n;
}

static NSString *docs_dir(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
}

static void refresh_romfs_overlay_env(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *ov = [NSMutableArray array];
    NSString *docOv = [docs_dir() stringByAppendingPathComponent:@"romfs_overlay"];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:docOv isDirectory:&isDir] && isDir) [ov addObject:docOv];
    NSString *appOv = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs_overlay"];
    if ([fm fileExistsAtPath:appOv isDirectory:&isDir] && isDir) [ov addObject:appOv];
    if (ov.count) setenv("DM_ROMFS_OVERLAY", [ov componentsJoinedByString:@":"].fileSystemRepresentation, 1);
    else unsetenv("DM_ROMFS_OVERLAY");
}

static BOOL replace_dir_safely(NSString *target, NSString *src, NSString *backupBaseDir, NSString **errOut) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *err = nil;
    if (backupBaseDir && [fm fileExistsAtPath:target] && count_files_recursive(target) > 0) {
        [fm createDirectoryAtPath:backupBaseDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *bkp = [backupBaseDir stringByAppendingPathComponent:[NSString stringWithFormat:@"before-import-%@", [df stringFromDate:[NSDate date]]]];
        if (![fm copyItemAtPath:target toPath:bkp error:&err]) {
            if (errOut) *errOut = err.localizedDescription ?: @"Could not back up existing save.";
            return NO;
        }
    }
    NSString *oldTemp = [target stringByAppendingFormat:@".old-%@", NSUUID.UUID.UUIDString];
    BOOL hadOld = [fm fileExistsAtPath:target];
    if (hadOld && ![fm moveItemAtPath:target toPath:oldTemp error:&err]) {
        if (errOut) *errOut = err.localizedDescription ?: @"Could not move existing folder aside.";
        return NO;
    }
    if (![fm moveItemAtPath:src toPath:target error:&err]) {
        if (hadOld) [fm moveItemAtPath:oldTemp toPath:target error:nil];
        if (errOut) *errOut = err.localizedDescription ?: @"Could not place imported folder.";
        return NO;
    }
    if (hadOld) [fm removeItemAtPath:oldTemp error:nil];
    return YES;
}

NSString *dm_import_save_zip(NSURL *zipURL, NSUInteger *fileCountOut) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = docs_dir();
    NSString *stage = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"dm-save-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *err = nil;
    BOOL ok = extract_zip_to_dir(zipURL, stage, fileCountOut, &err);
    if (ok) {
        NSString *src = unwrap_single_root(stage, NO);
        NSString *saveDir = [doc stringByAppendingPathComponent:@"save"];
        [fm removeItemAtPath:[doc stringByAppendingPathComponent:@"save.work"] error:nil];
        [fm removeItemAtPath:[doc stringByAppendingPathComponent:@"save.new"] error:nil];
        ok = replace_dir_safely(saveDir, src, [doc stringByAppendingPathComponent:@"save-backups"], &err);
    }
    [fm removeItemAtPath:stage error:nil];
    return ok ? nil : (err ?: @"Save import failed.");
}

NSString *dm_import_romfs_mod_zip(NSURL *zipURL, NSUInteger *fileCountOut) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = docs_dir();
    NSString *stage = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"dm-mod-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *err = nil;
    BOOL ok = extract_zip_to_dir(zipURL, stage, fileCountOut, &err);
    if (ok) {
        NSString *src = unwrap_single_root(stage, YES);
        NSString *ovDir = [doc stringByAppendingPathComponent:@"romfs_overlay"];
        ok = replace_dir_safely(ovDir, src, nil, &err);
        if (ok) refresh_romfs_overlay_env();
    }
    [fm removeItemAtPath:stage error:nil];
    return ok ? nil : (err ?: @"RomFS mod import failed.");
}

void dm_clear_romfs_mods(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:[docs_dir() stringByAppendingPathComponent:@"romfs_overlay"] error:nil];
    refresh_romfs_overlay_env();
}

NSUInteger dm_romfs_mod_file_count(void) {
    NSString *ovDir = [docs_dir() stringByAppendingPathComponent:@"romfs_overlay"];
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:ovDir isDirectory:&isDir] || !isDir) return 0;
    return count_files_recursive(ovDir);
}

BOOL dm_has_bundled_romfs_mod(void) {
    NSString *appOv = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs_overlay"];
    BOOL isDir = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:appOv isDirectory:&isDir] && isDir;
}
