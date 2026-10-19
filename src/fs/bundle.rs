/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! IPA file format support, allowing it to be used as part of the guest
//! filesystem.
use crate::fs::{FsNode, GuestPath};
use crate::libc::time::{calendar_date_to_timestamp, time_t, tm};
use std::cell::RefCell;
use std::collections::HashMap;
#[cfg(not(target_os = "ios"))]
use std::collections::VecDeque;
use std::fmt::Debug;
#[cfg(not(target_os = "ios"))]
use std::io::Cursor;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::rc::Rc;
#[cfg(not(target_os = "ios"))]
use zip::result::ZipError;
use zip::ZipArchive;

/// A helper struct to build an FsNode with files and directories coming in
/// arbitrary order. This is required, because ZIP files are allowed to store
/// entries in arbitrary order.
struct FsNodeBuilder {
    root: FsNode,
}

impl FsNodeBuilder {
    fn new() -> Self {
        Self {
            root: FsNode::dir(),
        }
    }

    fn find_or_make_directory(&mut self, path: &GuestPath) -> &mut FsNode {
        let mut current = &mut self.root;
        for part in path.as_str().split('/') {
            if part.is_empty() {
                continue;
            }
            assert_ne!(part, "..", "unexpected .. in path: {path:?}");
            let FsNode::Directory { children, .. } = current else {
                panic!("expected directory, got {current:?}");
            };

            let next = children.entry(part.to_string()).or_insert_with(FsNode::dir);
            current = next;
        }
        current
    }

    fn add_file(&mut self, path: &GuestPath, node: FsNode) {
        let (parent_name, file_name) = path.parent_and_file_name().unwrap();
        assert_ne!(file_name, "..", "unexpected .. in path: {path:?}");
        let dir = self.find_or_make_directory(parent_name);
        let FsNode::Directory { children, .. } = dir else {
            panic!("expected directory, got {dir:?}");
        };

        children.insert(file_name.to_string(), node);
    }

    fn add_directory(&mut self, path: &GuestPath) {
        self.find_or_make_directory(path);
    }

    fn build(self) -> FsNode {
        self.root
    }
}

/// Represents an open app bundle, either a directory or a zip file.
pub enum BundleData {
    HostDirectory(PathBuf),
    Zip {
        zip: ZipArchive<std::fs::File>,
        /// Path to the app bundle inside the zip file.
        /// It should be `"Payload/<app name>.app"` (no trailing slash!).
        bundle_path: String,
    },
}

impl BundleData {
    fn find_bundle_path_in_archive(zip: &mut ZipArchive<std::fs::File>) -> Result<String, String> {
        for i in 0..zip.len() {
            let file = zip
                .by_index(i)
                .map_err(|e| format!("Could not open IPA archive entry: {e}"))?;
            let path = file.name();
            if let Some(name) = path
                .strip_prefix("Payload/")
                .and_then(|path| path.split_once('/'))
                .and_then(|(name, _)| name.strip_suffix(".app"))
            {
                return Ok(format!("Payload/{name}.app"));
            }
        }
        Err("no app bundle found in the IPA archive".to_string())
    }

    pub fn bundle_name(&self) -> &str {
        match self {
            BundleData::HostDirectory(bundle_path) => {
                bundle_path.file_stem().unwrap().to_str().unwrap()
            }
            BundleData::Zip { bundle_path, .. } => bundle_path
                .rsplit_once('/')
                .unwrap()
                .1
                .strip_suffix(".app")
                .unwrap(),
        }
    }

    pub fn open_host_dir(path: &Path) -> Result<BundleData, String> {
        Ok(BundleData::HostDirectory(path.to_path_buf()))
    }

    pub fn open_ipa(path: &Path) -> Result<BundleData, String> {
        let file =
            std::fs::File::open(path).map_err(|e| format!("Could not open IPA file: {e}"))?;
        let mut zip =
            ZipArchive::new(file).map_err(|e| format!("Could not open IPA archive: {e}"))?;
        let bundle_path = Self::find_bundle_path_in_archive(&mut zip)?;
        Ok(BundleData::Zip { zip, bundle_path })
    }

    pub fn open_any(path: &Path) -> Result<BundleData, String> {
        if path.is_file()
            && path
                .extension()
                .map(|ext| ext.eq_ignore_ascii_case("ipa"))
                .unwrap_or(false)
        {
            Ok(Self::open_ipa(path)?)
        } else if path.is_dir() {
            Ok(Self::open_host_dir(path)?)
        } else {
            Err(format!(
                "{} is not a directory or an IPA file",
                path.display()
            ))
        }
    }

    pub(super) fn into_fs_node(self) -> FsNode {
        match self {
            BundleData::HostDirectory(path) => FsNode::from_host_dir(&path, false),
            BundleData::Zip { zip, bundle_path } => {
                let archive = Rc::new(RefCell::new(zip));
                let archive_cache = Rc::new(RefCell::new(ArchiveFileCache::new()));
                let metadata_map = Rc::new(RefCell::new(HashMap::new()));

                let mut archive_guard = (*archive).borrow_mut();

                let mut builder = FsNodeBuilder::new();
                for i in 0..archive_guard.len() {
                    let file = archive_guard.by_index(i).unwrap(); // TODO: report IO error?
                    let name = file.name();
                    if let Some(path) = name.strip_prefix(&bundle_path) {
                        let path = GuestPath::new(path);
                        if file.is_dir() {
                            builder.add_directory(path);
                        } else {
                            builder.add_file(
                                path,
                                FsNode::bundle_zip_file(IpaFileRef {
                                    archive: archive.clone(),
                                    archive_files_cache: archive_cache.clone(),
                                    metadata_map: metadata_map.clone(),
                                    index: i,
                                }),
                            );
                        }
                    }
                }
                builder.build()
            }
        }
    }

    pub fn read_plist(&mut self) -> Result<Vec<u8>, String> {
        match self {
            BundleData::HostDirectory(path) => {
                std::fs::read(path.join("Info.plist")).map_err(|e| {
                    format!("Could not read Info.plist from the app bundle directory: {e}")
                })
            }
            BundleData::Zip { zip, bundle_path } => {
                let mut file = zip
                    .by_name(&format!("{bundle_path}/Info.plist"))
                    .map_err(|e| format!("Could not open Info.plist from the IPA archive: {e}"))?;
                let mut buf = Vec::new();
                file.read_to_end(&mut buf)
                    .map_err(|e| format!("Could not read Info.plist from the IPA archive: {e}"))?;
                Ok(buf)
            }
        }
    }
}

#[derive(Debug)]
struct ArchivedFileMetadata {
    /// Unix timestamp of file modification
    last_modified: i64,
    /// Uncompressed file size
    size: u64,
}

/// Shared (refcounted) copy of the decompressed version of a file in an IPA.
///
/// Seeking in compressed files is hard, so the simple solution is to read the
/// whole file into memory. This is shared so having multiple copies of the same
/// file open won't waste memory.
#[cfg(not(target_os = "ios"))]
type DecompressedFile = Rc<[u8]>;

#[cfg(not(target_os = "ios"))]
const ARCHIVE_CACHE_CAPACITY: usize = usize::MAX;

#[cfg(not(target_os = "ios"))]
#[derive(Debug)]
struct ArchiveFileCache {
    files: HashMap<usize, DecompressedFile>,
    lru: VecDeque<usize>,
    bytes: usize,
}

#[cfg(not(target_os = "ios"))]
impl ArchiveFileCache {
    fn new() -> Self {
        Self {
            files: HashMap::new(),
            lru: VecDeque::new(),
            bytes: 0,
        }
    }

    fn get(&mut self, index: usize) -> Option<DecompressedFile> {
        let file = Rc::clone(self.files.get(&index)?);
        self.lru.retain(|&cached_index| cached_index != index);
        self.lru.push_back(index);
        Some(file)
    }

    fn insert(&mut self, index: usize, file: DecompressedFile) -> DecompressedFile {
        // A single entry larger than the whole budget remains alive through
        // the returned IpaFile handle, but must not pin that memory after the
        // guest closes it.
        if file.len() > ARCHIVE_CACHE_CAPACITY {
            return file;
        }

        while self.bytes.saturating_add(file.len()) > ARCHIVE_CACHE_CAPACITY {
            let Some(oldest_index) = self.lru.pop_front() else {
                break;
            };
            if let Some(oldest) = self.files.remove(&oldest_index) {
                self.bytes = self.bytes.saturating_sub(oldest.len());
            }
        }

        self.bytes = self.bytes.saturating_add(file.len());
        self.files.insert(index, Rc::clone(&file));
        self.lru.push_back(index);
        file
    }
}

// iOS 12 gives this process a roughly 700 MiB resident-memory limit on the
// iPad mini 3. Some games contain more than 800 MiB of uncompressed resources
// and keep many file descriptors open, so even a bounded in-memory cache is
// insufficient: open handles continue to pin their complete buffers. Store
// decompressed entries in the app's native temporary directory instead. The
// kernel can reclaim clean file-system cache pages under memory pressure.
#[cfg(target_os = "ios")]
#[derive(Debug)]
struct ArchiveFileCache {
    directory: PathBuf,
    files: HashMap<usize, PathBuf>,
}

#[cfg(target_os = "ios")]
impl ArchiveFileCache {
    fn new() -> Self {
        let directory = std::env::temp_dir().join("touchHLE-ipa-cache");
        match std::fs::remove_dir_all(&directory) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => log!(
                "Warning: could not clear stale IPA disk cache at {:?}: {}",
                directory,
                e
            ),
        }
        std::fs::create_dir_all(&directory).unwrap_or_else(|e| {
            panic!(
                "Could not create IPA disk cache directory {:?}: {}",
                directory, e
            )
        });
        Self {
            directory,
            files: HashMap::new(),
        }
    }

    fn get(&self, index: usize) -> Option<PathBuf> {
        self.files.get(&index).cloned()
    }

    fn paths_for(&self, index: usize) -> (PathBuf, PathBuf) {
        let final_path = self.directory.join(index.to_string());
        let partial_path = self.directory.join(format!("{index}.partial"));
        (final_path, partial_path)
    }

    fn insert(&mut self, index: usize, path: PathBuf) {
        self.files.insert(index, path);
    }

    fn remove(&mut self, index: usize) {
        self.files.remove(&index);
    }
}

#[cfg(target_os = "ios")]
impl Drop for ArchiveFileCache {
    fn drop(&mut self) {
        if let Err(e) = std::fs::remove_dir_all(&self.directory) {
            if e.kind() != std::io::ErrorKind::NotFound {
                log!(
                    "Warning: could not remove IPA disk cache at {:?}: {}",
                    self.directory,
                    e
                );
            }
        }
    }
}

/// Represents a file inside an IPA bundle that can be opened.
#[derive(Debug)]
pub struct IpaFileRef {
    archive: Rc<RefCell<ZipArchive<std::fs::File>>>,
    archive_files_cache: Rc<RefCell<ArchiveFileCache>>,
    metadata_map: Rc<RefCell<HashMap<usize, ArchivedFileMetadata>>>,
    index: usize,
}

impl IpaFileRef {
    pub fn open(&self) -> IpaFile {
        #[cfg(target_os = "ios")]
        {
            self.open_disk_backed()
        }
        #[cfg(not(target_os = "ios"))]
        {
            self.open_memory_backed()
        }
    }

    #[cfg(not(target_os = "ios"))]
    fn open_memory_backed(&self) -> IpaFile {
        // Some games, like THPS2, use a single resource bundle file which is
        // opened each time a new game resource is being read.
        // As IPA is basically an archive, this pattern requires unzipping to be
        // done each time, which is extremely slow.
        // Keep recently unzipped data in memory so repeated reads remain fast.
        // On memory-constrained iOS devices this cache has a strict LRU budget.
        if let Some(cached_file) = self.archive_files_cache.borrow_mut().get(self.index) {
            return IpaFile {
                file: Cursor::new(cached_file),
            };
        }

        let decoded_file = {
            // Read the zip entry into an owned buffer inside its own block so
            // the `archive` RefMut is released before we touch the caches.
            let mut archive = (*self.archive).borrow_mut();
            let decoded: Option<(Vec<u8>, ArchivedFileMetadata)> = match archive
                .by_index(self.index)
            {
                Ok(mut file) => {
                    let modified = file.last_modified();
                    // This is not the cleanest way!
                    // TODO: just use `time` or `chrono` crates for time conversions
                    // (this also entails a lot of refactoring in [crate::libc:time])
                    let tm = tm::from(
                        modified.year(),
                        modified.month(),
                        modified.day(),
                        modified.hour(),
                        modified.minute(),
                        modified.second(),
                    );
                    let timestamp = calendar_date_to_timestamp(tm);
                    let size = file.size();
                    let mut buf = Vec::new();
                    if let Err(e) = file.read_to_end(&mut buf) {
                        log!(
                            "Warning: IpaFileRef::open(): IO error decompressing IPA entry {}: {}; returning partial buffer ({} bytes) to guest.",
                            self.index,
                            e,
                            buf.len()
                        );
                    }
                    Some((
                        buf,
                        ArchivedFileMetadata {
                            last_modified: timestamp.into(),
                            size,
                        },
                    ))
                }
                Err(ZipError::Io(e)) => {
                    log!(
                        "Warning: IpaFileRef::open(): IO error reading IPA entry {}: {}; returning empty file to guest.",
                        self.index,
                        e
                    );
                    None
                }
                Err(e) => {
                    log!(
                        "Warning: IpaFileRef::open(): could not open IPA entry {}: {}; returning empty file to guest.",
                        self.index,
                        e
                    );
                    None
                }
            };
            drop(archive);

            match decoded {
                Some((buf, meta)) => {
                    (*self.metadata_map)
                        .borrow_mut()
                        .entry(self.index)
                        .or_insert(meta);
                    Rc::from(buf)
                }
                None => Rc::from(Vec::new()),
            }
        };
        let cached_file = self
            .archive_files_cache
            .borrow_mut()
            .insert(self.index, decoded_file);
        IpaFile {
            file: Cursor::new(cached_file),
        }
    }

    #[cfg(target_os = "ios")]
    fn open_disk_backed(&self) -> IpaFile {
        let cached_path = self.archive_files_cache.borrow().get(self.index);
        if let Some(path) = cached_path {
            match std::fs::File::open(&path) {
                Ok(file) => return IpaFile { file },
                Err(e) => {
                    log!(
                        "Warning: cached IPA entry {} at {:?} disappeared: {}; extracting it again.",
                        self.index,
                        path,
                        e
                    );
                    self.archive_files_cache.borrow_mut().remove(self.index);
                }
            }
        }

        let (final_path, partial_path) = self
            .archive_files_cache
            .borrow()
            .paths_for(self.index);
        let mut output = std::fs::File::create(&partial_path).unwrap_or_else(|e| {
            panic!(
                "Could not create disk cache for IPA entry {} at {:?}: {}",
                self.index, partial_path, e
            )
        });

        let metadata = {
            let mut archive = (*self.archive).borrow_mut();
            let metadata = match archive.by_index(self.index) {
                Ok(mut file) => {
                    let modified = file.last_modified();
                    let tm = tm::from(
                        modified.year(),
                        modified.month(),
                        modified.day(),
                        modified.hour(),
                        modified.minute(),
                        modified.second(),
                    );
                    let size = file.size();
                    if let Err(e) = std::io::copy(&mut file, &mut output) {
                        log!(
                            "Warning: IpaFileRef::open(): IO error extracting IPA entry {} to disk: {}; returning partial file to guest.",
                            self.index,
                            e
                        );
                    }
                    ArchivedFileMetadata {
                        last_modified: calendar_date_to_timestamp(tm).into(),
                        size,
                    }
                }
                Err(e) => {
                    log!(
                        "Warning: IpaFileRef::open(): could not open IPA entry {}: {}; returning empty file to guest.",
                        self.index,
                        e
                    );
                    ArchivedFileMetadata {
                        last_modified: 0,
                        size: 0,
                    }
                }
            };
            metadata
        };
        drop(output);

        std::fs::rename(&partial_path, &final_path).unwrap_or_else(|e| {
            panic!(
                "Could not finalize disk cache for IPA entry {} from {:?} to {:?}: {}",
                self.index, partial_path, final_path, e
            )
        });
        self.archive_files_cache
            .borrow_mut()
            .insert(self.index, final_path.clone());
        self.metadata_map
            .borrow_mut()
            .entry(self.index)
            .or_insert(metadata);

        let file = std::fs::File::open(&final_path).unwrap_or_else(|e| {
            panic!(
                "Could not reopen disk-cached IPA entry {} at {:?}: {}",
                self.index, final_path, e
            )
        });
        IpaFile { file }
    }

    fn ensure_metadata(&self) {
        if self.metadata_map.borrow().contains_key(&self.index) {
            return;
        }

        let metadata = {
            let mut archive = (*self.archive).borrow_mut();
            let metadata = match archive.by_index(self.index) {
                Ok(file) => {
                    let modified = file.last_modified();
                    let tm = tm::from(
                        modified.year(),
                        modified.month(),
                        modified.day(),
                        modified.hour(),
                        modified.minute(),
                        modified.second(),
                    );
                    ArchivedFileMetadata {
                        last_modified: calendar_date_to_timestamp(tm).into(),
                        size: file.size(),
                    }
                }
                Err(e) => {
                    log!(
                        "Warning: IpaFileRef metadata lookup for entry {} failed: {}; using zero values.",
                        self.index,
                        e
                    );
                    ArchivedFileMetadata {
                        last_modified: 0,
                        size: 0,
                    }
                }
            };
            metadata
        };
        self.metadata_map
            .borrow_mut()
            .entry(self.index)
            .or_insert(metadata);
    }

    pub fn get_last_modified(&self) -> time_t {
        self.ensure_metadata();
        self.metadata_map
            .borrow()
            .get(&self.index)
            .unwrap()
            .last_modified
            .try_into()
            .unwrap()
    }
    pub fn get_size(&self) -> u64 {
        self.ensure_metadata();
        self.metadata_map.borrow().get(&self.index).unwrap().size
    }
}

/// Represents an opened file in an IPA bundle.
pub struct IpaFile {
    #[cfg(not(target_os = "ios"))]
    file: Cursor<DecompressedFile>,
    #[cfg(target_os = "ios")]
    file: std::fs::File,
}

impl Clone for IpaFile {
    fn clone(&self) -> Self {
        #[cfg(not(target_os = "ios"))]
        {
            Self {
                file: self.file.clone(),
            }
        }
        #[cfg(target_os = "ios")]
        {
            Self {
                // This matches POSIX dup semantics: both descriptors share a
                // file offset, just like GuestFile::File.
                file: self.file.try_clone().unwrap_or_else(|e| {
                    panic!("Could not duplicate disk-cached IPA file: {e}")
                }),
            }
        }
    }
}

impl Debug for IpaFile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        #[cfg(not(target_os = "ios"))]
        let size = self.file.get_ref().len();
        #[cfg(target_os = "ios")]
        let size = self.file.metadata().map(|metadata| metadata.len()).unwrap_or(0);
        f.debug_struct("IpaFile")
            .field("size", &size)
            .finish()
    }
}

impl Read for IpaFile {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.file.read(buf)
    }
}

impl std::io::Seek for IpaFile {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        self.file.seek(pos)
    }
}
