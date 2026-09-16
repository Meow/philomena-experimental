import { $, $$, clearEl } from './utils/dom';
import { assertNotNull } from './utils/assert';
import store from './utils/store';
import { ImageVersion, ImageUris, MediaSupplements } from './utils/media';

type ScaledState = 'true' | 'false' | 'partscaled';

type ImageVersionDimensions = [ImageVersion, [number, number]];

export interface ImageTargetElement extends HTMLElement {
  dataset: DOMStringMap & {
    width: string;
    height: string;
    imageSize: string;
    mimeType: string;
    scaled: ScaledState;
    uris: string;
    supplements: string;
  };
}

const imageVersions: ImageVersionDimensions[] = [
  // [width, height]
  ['small', [320, 240]],
  ['medium', [800, 600]],
  ['large', [1280, 1024]],
];

/**
 * Picks the appropriate image version for a given width and height
 * of the viewport and the image dimensions.
 */
export function selectVersion(
  imageWidth: number,
  imageHeight: number,
  imageSize: number,
  imageMime: string,
): ImageVersion {
  let viewWidth = document.documentElement.clientWidth;
  let viewHeight = document.documentElement.clientHeight;

  // load hires if that's what you asked for
  if (store.get<boolean>('serve_hidpi')) {
    viewWidth *= window.devicePixelRatio || 1;
    viewHeight *= window.devicePixelRatio || 1;
  }

  if (viewWidth > 1024 && imageHeight > 1024 && imageHeight > 2.5 * imageWidth) {
    // Treat as comic-sized dimensions..
    return 'tall';
  }

  // Find a version that is larger than the view in one/both axes
  // .find() is not supported in older browsers, using a loop
  for (const [version, [versionWidth, versionHeight]] of imageVersions) {
    const maxWidth = Math.min(imageWidth, versionWidth);
    const maxHeight = Math.min(imageHeight, versionHeight);
    if (maxWidth > viewWidth || maxHeight > viewHeight) {
      return version;
    }
  }

  // If the view is larger than any available version, display the original image.
  //
  // Sanity check to make sure we're not serving unintentionally huge assets
  // all at once (where "huge" > 25 MiB). Videos are loaded in chunks so it
  // doesn't matter too much there.
  if (imageMime === 'video/webm' || imageSize <= 26_214_400) {
    return 'full';
  }

  return 'large';
}

/**
 * Given a target container element, chooses and scales an image
 * to an appropriate dimension.
 */
export function pickAndResize(elem: ImageTargetElement) {
  const imageWidth = parseInt(elem.dataset.width, 10);
  const imageHeight = parseInt(elem.dataset.height, 10);
  const imageSize = parseInt(elem.dataset.imageSize, 10);
  const imageMime = elem.dataset.mimeType;
  const scaled = elem.dataset.scaled;
  const uris: ImageUris = JSON.parse(elem.dataset.uris);
  const supplements: MediaSupplements = JSON.parse(elem.dataset.supplements);

  let version: ImageVersion = 'full';

  if (scaled === 'true') {
    version = selectVersion(imageWidth, imageHeight, imageSize, imageMime);
  }

  const uri = uris[version];
  if (!uri) return;

  if (supplements.type === 'webm') {
    showVideo(elem, { webm: uri, mp4: supplements.mp4_thumbnails[version].uri });
  } else if (version === 'full' && supplements.type === 'gif' && store.get<boolean>('serve_webm')) {
    showVideo(
      elem,
      { webm: supplements.webm.uri, mp4: supplements.mp4.uri },
      { width: imageWidth, height: imageHeight },
    );
  } else {
    showImage(elem, uri, version, imageWidth, imageHeight);
  }
}

function applyScaling(media: HTMLImageElement | HTMLVideoElement, scaled: ScaledState) {
  if (scaled === 'true') {
    media.className = 'image-scaled';
  } else if (scaled === 'partscaled') {
    media.className = 'image-partscaled';
  }
}

function showVideo(
  elem: ImageTargetElement,
  sources: { webm: string; mp4: string },
  gifDimensions?: { width: number; height: number },
) {
  const currentSources = $$<HTMLSourceElement>('video source', elem);
  if (
    currentSources.length === 2 &&
    currentSources[0].getAttribute('src') === sources.webm &&
    currentSources[1].getAttribute('src') === sources.mp4
  ) {
    // Do nothing if the source will stay the same to avoid flicker
    return;
  }

  clearEl(elem);
  elem.classList.toggle('full-height', Boolean(gifDimensions));

  const muted = store.get<boolean>('unmute_videos') ? '' : 'muted';
  const autoplay = elem.classList.contains('hidden') ? '' : 'autoplay'; // Fix for spoilered image pages
  const dimensions = gifDimensions
    ? `width="${gifDimensions.width}" height="${gifDimensions.height}" preload="auto"`
    : '';

  elem.insertAdjacentHTML(
    'afterbegin',
    `<video controls ${autoplay} loop ${muted} playsinline ${dimensions} id="image-display">
      <source src="${sources.webm}" type="video/webm">
      <source src="${sources.mp4}" type="video/mp4">
      <p class="block block--fixed block--warning">
        Your browser supports neither MP4/H264 nor
        WebM/VP8! Please update it to the latest version.
      </p>
     </video>`,
  );

  if (!gifDimensions) {
    applyScaling(assertNotNull($<HTMLVideoElement>('video', elem)), elem.dataset.scaled);
  }
}

function showImage(
  elem: ImageTargetElement,
  uri: string,
  version: ImageVersion,
  imageWidth: number,
  imageHeight: number,
) {
  elem.classList.remove('full-height');

  const picture = document.createElement('picture');
  const img = document.createElement('img');
  picture.appendChild(img);
  img.id = 'image-display';
  img.src = uri;
  if (version === 'full') {
    // Let layout engine know image size before it arrives
    img.width = imageWidth;
    img.height = imageHeight;
  }
  applyScaling(img, elem.dataset.scaled);
  if (elem.children.length === 1 && elem.children[0].isEqualNode(picture)) return;

  clearEl(elem);
  elem.appendChild(picture);
}

/**
 * Bind an event to an image container for updating an image on
 * click/tap.
 */
function bindImageForClick(target: ImageTargetElement) {
  target.addEventListener('click', () => {
    const currentScaled = target.getAttribute('data-scaled');
    if (currentScaled === 'true') {
      target.setAttribute('data-scaled', 'partscaled');
    } else if (currentScaled === 'partscaled') {
      target.setAttribute('data-scaled', 'false');
    } else {
      target.setAttribute('data-scaled', 'true');
    }

    pickAndResize(target);
  });
}

/**
 * Bind image targets within a context.
 */
export function bindImageTarget(node: Pick<Document, 'querySelectorAll'> = document) {
  $$<ImageTargetElement>('.image-target', node).forEach(target => {
    pickAndResize(target);

    if (target.dataset.mimeType === 'video/webm') {
      // Don't interfere with media controls on video
      return;
    }

    bindImageForClick(target);

    window.addEventListener('resize', () => {
      pickAndResize(target);
    });
  });
}
