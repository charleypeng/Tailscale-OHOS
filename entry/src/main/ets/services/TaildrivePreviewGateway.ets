import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { TaildriveEntry } from './TaildriveGateway';

const THUMBNAIL_EDGE_PX: number = 160;
const THUMBNAIL_QUALITY: number = 76;

export interface TaildriveCachedPreview {
  path: string;
  thumbnailPath: string;
}

/** Owns private remote-file preview downloads and their derived thumbnails. */
export class TaildrivePreviewGateway {
  root(context: common.Context): string {
    return `${context.cacheDir}/taildrive-previews`;
  }

  cachedPreview(context: common.Context, entry: TaildriveEntry): TaildriveCachedPreview | undefined {
    const path: string = this.previewPath(context, entry);
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (!stat.isFile() || (entry.size > 0 && stat.size !== entry.size)) {
        return undefined;
      }
      const thumbnailPath: string = this.thumbnailPath(path);
      return {
        path: path,
        thumbnailPath: this.validFile(thumbnailPath) ? thumbnailPath : ''
      };
    } catch (_error) {
      return undefined;
    }
  }

  prepareDownload(context: common.Context, entry: TaildriveEntry): string {
    const path: string = this.previewPath(context, entry);
    const thumbnailPath: string = this.thumbnailPath(path);
    this.prepareDestination(path);
    this.removeIfPresent(thumbnailPath);
    return path;
  }

  async createThumbnail(context: common.Context, entry: TaildriveEntry, sourcePath: string): Promise<string> {
    if (!this.isImage(entry) && !this.isVideo(entry)) {
      return '';
    }
    const destination: string = this.thumbnailPath(sourcePath);
    if (this.validFile(destination)) {
      return destination;
    }
    try {
      return this.isImage(entry) ?
        await this.createImageThumbnail(sourcePath, destination) :
        await this.createVideoThumbnail(sourcePath, destination);
    } catch (_error) {
      this.removeIfPresent(destination);
      return '';
    }
  }

  private previewPath(context: common.Context, entry: TaildriveEntry): string {
    // Keep cache keys in directories so the opened file retains its remote name.
    return `${this.root(context)}/${this.cacheKey(entry)}/${this.safeName(entry.name)}`;
  }

  private thumbnailPath(sourcePath: string): string {
    return `${sourcePath}.thumb.jpg`;
  }

  private cacheKey(entry: TaildriveEntry): string {
    const value: string = `${entry.path}\n${entry.name}`;
    let hash: number = 2166136261;
    for (let index: number = 0; index < value.length; index++) {
      hash ^= value.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16);
  }

  private safeName(name: string): string {
    const slash: number = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
    const base: string = slash >= 0 ? name.substring(slash + 1) : name;
    const value: string = base.replace(/[\\/:*?"<>|]/g, '_').trim();
    return value.length > 0 && value !== '.' && value !== '..' ? value : 'remote-file';
  }

  private validFile(path: string): boolean {
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      return stat.isFile() && stat.size > 0;
    } catch (_error) {
      return false;
    }
  }

  private removeIfPresent(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (_error) {
    }
  }

  private isImage(entry: TaildriveEntry): boolean {
    const contentType: string = (entry.contentType ?? '').toLowerCase();
    if (contentType.startsWith('image/')) {
      return true;
    }
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg']
      .includes(this.extension(entry.name));
  }

  private isVideo(entry: TaildriveEntry): boolean {
    const contentType: string = (entry.contentType ?? '').toLowerCase();
    if (contentType.startsWith('video/')) {
      return true;
    }
    return ['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', '3gp']
      .includes(this.extension(entry.name));
  }

  private extension(name: string): string {
    const dot: number = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  private prepareDestination(destination: string): void {
    const separator: number = destination.lastIndexOf('/');
    if (separator > 0) {
      const parent: string = destination.substring(0, separator);
      if (!fileIo.accessSync(parent)) {
        fileIo.mkdirSync(parent, true);
      }
    }
    this.removeIfPresent(destination);
  }

  private async writeThumbnail(pixelMap: image.PixelMap, destination: string): Promise<string> {
    let packer: image.ImagePacker | undefined = undefined;
    let destinationFile: fileIo.File | undefined = undefined;
    try {
      this.prepareDestination(destination);
      packer = image.createImagePacker();
      const packed: ArrayBuffer = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: THUMBNAIL_QUALITY
      });
      if (packed.byteLength <= 0) {
        return '';
      }
      destinationFile = fileIo.openSync(destination,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const written: number = fileIo.writeSync(destinationFile.fd, packed);
      fileIo.closeSync(destinationFile);
      destinationFile = undefined;
      return written === packed.byteLength && this.validFile(destination) ? destination : '';
    } catch (_error) {
      this.removeIfPresent(destination);
      return '';
    } finally {
      if (destinationFile !== undefined) {
        try {
          fileIo.closeSync(destinationFile);
        } catch (_error) {
        }
      }
      if (packer !== undefined) {
        try {
          await packer.release();
        } catch (_error) {
        }
      }
    }
  }

  private async createImageThumbnail(sourcePath: string, destination: string): Promise<string> {
    let sourceFile: fileIo.File | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(sourceFile.fd);
      const info: image.ImageInfo = await imageSource.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        return '';
      }
      let width: number = THUMBNAIL_EDGE_PX;
      let height: number = THUMBNAIL_EDGE_PX;
      if (info.size.width >= info.size.height) {
        height = Math.max(1, Math.round(THUMBNAIL_EDGE_PX * info.size.height / info.size.width));
      } else {
        width = Math.max(1, Math.round(THUMBNAIL_EDGE_PX * info.size.width / info.size.height));
      }
      pixelMap = await imageSource.createPixelMap({
        index: 0,
        desiredSize: { width: width, height: height }
      });
      return await this.writeThumbnail(pixelMap, destination);
    } catch (_error) {
      this.removeIfPresent(destination);
      return '';
    } finally {
      if (pixelMap !== undefined) {
        try {
          await pixelMap.release();
        } catch (_error) {
        }
      }
      if (imageSource !== undefined) {
        try {
          await imageSource.release();
        } catch (_error) {
        }
      }
      if (sourceFile !== undefined) {
        try {
          fileIo.closeSync(sourceFile);
        } catch (_error) {
        }
      }
    }
  }

  private async createVideoThumbnail(sourcePath: string, destination: string): Promise<string> {
    let sourceFile: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      sourceFile = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(sourceFile.fd);
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: sourceFile.fd, offset: 0, length: stat.size };
      const metadata: media.AVMetadata = await extractor.fetchMetadata();
      const sourceWidth: number = metadata.videoWidth === undefined ? 0 : Number(metadata.videoWidth);
      const sourceHeight: number = metadata.videoHeight === undefined ? 0 : Number(metadata.videoHeight);
      let width: number = THUMBNAIL_EDGE_PX;
      let height: number = THUMBNAIL_EDGE_PX;
      if (sourceWidth > 0 && sourceHeight > 0 && Number.isFinite(sourceWidth) && Number.isFinite(sourceHeight)) {
        if (sourceWidth >= sourceHeight) {
          height = Math.max(1, Math.round(THUMBNAIL_EDGE_PX * sourceHeight / sourceWidth));
        } else {
          width = Math.max(1, Math.round(THUMBNAIL_EDGE_PX * sourceWidth / sourceHeight));
        }
      }
      const durationMs: number = metadata.duration === undefined ? 0 : Number(metadata.duration);
      const frameTimeUs: number = Number.isFinite(durationMs) && durationMs > 0 ?
        Math.min(1000000, Math.round(durationMs * 250)) : 0;
      pixelMap = await extractor.fetchFrameByTime(
        frameTimeUs,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
        { width: width, height: height });
      return await this.writeThumbnail(pixelMap, destination);
    } catch (_error) {
      this.removeIfPresent(destination);
      return '';
    } finally {
      if (pixelMap !== undefined) {
        try {
          await pixelMap.release();
        } catch (_error) {
        }
      }
      if (extractor !== undefined) {
        try {
          await extractor.release();
        } catch (_error) {
        }
      }
      if (sourceFile !== undefined) {
        try {
          fileIo.closeSync(sourceFile);
        } catch (_error) {
        }
      }
    }
  }
}
