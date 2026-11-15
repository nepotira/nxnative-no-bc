#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Imports a `.zip` save archive into `Documents/save`, backing up any existing non-empty save
/// under `Documents/save-backups/` first. Returns nil on success, or an error description on failure.
NSString *_Nullable dm_import_save_zip(NSURL *zipURL, NSUInteger *_Nullable fileCountOut);

/// Imports a `.zip` RomFS mod archive (for example `PT_BR.zip`) into `Documents/romfs_overlay`
/// and updates `DM_ROMFS_OVERLAY` for the current session. Returns nil on success, or an error description.
NSString *_Nullable dm_import_romfs_mod_zip(NSURL *zipURL, NSUInteger *_Nullable fileCountOut);

/// Removes user-imported RomFS overlay mods from `Documents/romfs_overlay` and refreshes `DM_ROMFS_OVERLAY`.
void dm_clear_romfs_mods(void);

/// Returns how many regular files currently live in `Documents/romfs_overlay`.
NSUInteger dm_romfs_mod_file_count(void);

/// Returns YES if a bundled `<App>/romfs_overlay` directory ships inside the IPA.
BOOL dm_has_bundled_romfs_mod(void);

NS_ASSUME_NONNULL_END
