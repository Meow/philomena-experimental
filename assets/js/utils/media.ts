export type ImageVersion = 'small' | 'medium' | 'large' | 'tall' | 'full';
export type ThumbnailSize = ImageVersion | 'thumb' | 'thumb_small' | 'thumb_tiny';
export type ImageUris = Record<ThumbnailSize, string>;

interface MediaVersion {
  uri: string;
  width: number;
  height: number;
}

export type MediaSupplements =
  | { type: 'none' | 'not_rendered' | 'not_available' | 'destroyed' }
  | { type: 'svg'; static_preview: MediaVersion; svg: MediaVersion }
  | { type: 'gif'; static_preview: MediaVersion; webm: MediaVersion; mp4: MediaVersion }
  | {
      type: 'webm';
      static_preview: MediaVersion;
      mp4: MediaVersion;
      mp4_thumbnails: Record<ThumbnailSize, MediaVersion>;
      gif_previews: Record<'thumb' | 'thumb_small' | 'thumb_tiny', MediaVersion>;
    };
