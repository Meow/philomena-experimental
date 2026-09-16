import { assertNotNull } from './assert';
import { $, clearEl } from './dom';
import store from './store';
import { ImageUris, MediaSupplements, ThumbnailSize } from './media';

function getSpoilerOverlay(img: HTMLDivElement): HTMLElement {
  // This always exists in markup, regardless of the image type and state
  return assertNotNull($<HTMLElement>('.js-spoiler-info-overlay', img));
}

function getFilterExplanation(img: HTMLDivElement): HTMLElement {
  // This always exists in markup, regardless of the image type and state
  return assertNotNull($<HTMLElement>('.filter-explanation', img));
}

function showVideoThumb(img: HTMLDivElement, webm: string, mp4: string) {
  const vidEl = $<HTMLVideoElement>('video', img);
  if (!vidEl) return false;

  const imgEl = $<HTMLImageElement>('img', img);
  if (!imgEl || imgEl.classList.contains('hidden')) return false;

  imgEl.classList.add('hidden');

  vidEl.innerHTML = `
    <source src="${webm}" type="video/webm"/>
    <source src="${mp4}" type="video/mp4"/>
  `;
  vidEl.classList.remove('hidden');
  vidEl.play();

  getSpoilerOverlay(img).classList.add('hidden');

  return true;
}

export function showThumb(img: HTMLDivElement) {
  const size = img.dataset.size as ThumbnailSize | undefined;
  const urisString = img.dataset.uris;
  const supplementsString = img.dataset.supplements;
  if (!size || !urisString || !supplementsString) return false;

  const uris: ImageUris = JSON.parse(urisString);
  const supplements: MediaSupplements = JSON.parse(supplementsString);
  if (supplements.type === 'not_rendered' || supplements.type === 'not_available' || supplements.type === 'destroyed') {
    return false;
  }
  const preview =
    supplements.type === 'webm' && (size === 'thumb' || size === 'thumb_small' || size === 'thumb_tiny')
      ? supplements.gif_previews[size].uri
      : null;
  const thumbUri = preview ?? uris[size];

  const picEl = $<HTMLPictureElement>('picture', img);
  if (!picEl) {
    return supplements.type === 'webm' ? showVideoThumb(img, uris[size], supplements.mp4_thumbnails[size].uri) : false;
  }

  const imgEl = $<HTMLImageElement>('img', picEl);
  if (!imgEl || imgEl.src.indexOf(thumbUri) !== -1) return false;

  if (store.get('serve_hidpi') && supplements.type !== 'gif' && !preview) {
    // Check whether the HiDPI option is enabled, and make an exception for GIFs due to their size
    const x2Size = size === 'medium' ? uris.large : uris.medium;
    // use even larger thumb if normal size is medium already
    imgEl.srcset = `${thumbUri} 1x, ${x2Size} 2x`;
  }

  imgEl.src = thumbUri;
  const overlay = getSpoilerOverlay(img);

  if (supplements.type === 'webm') {
    overlay.classList.remove('hidden');
    overlay.innerHTML = 'WebM';
  } else {
    overlay.classList.add('hidden');
  }

  return true;
}

export function showBlock(img: HTMLDivElement) {
  $<HTMLElement>('.image-filtered', img)?.classList.add('hidden');
  const imageShowClasses = $<HTMLElement>('.image-show', img)?.classList;

  if (imageShowClasses) {
    imageShowClasses.remove('hidden');
    imageShowClasses.add('spoiler-pending');

    const vidEl = $<HTMLVideoElement>('video', img);
    if (vidEl) {
      vidEl.play();
    }
  }
}

function hideVideoThumb(img: HTMLDivElement, spoilerUri: string, reason: string) {
  const vidEl = $<HTMLVideoElement>('video', img);
  if (!vidEl) return;

  const imgEl = $<HTMLImageElement>('img', img);
  const imgOverlay = getSpoilerOverlay(img);
  if (!imgEl) return;

  imgEl.classList.remove('hidden');
  imgEl.src = spoilerUri;

  imgOverlay.innerHTML = reason;
  imgOverlay.classList.remove('hidden');

  clearEl(vidEl);
  vidEl.classList.add('hidden');
  vidEl.pause();
}

export function hideThumb(img: HTMLDivElement, spoilerUri: string, reason: string) {
  const picEl = $<HTMLPictureElement>('picture', img);
  if (!picEl) return hideVideoThumb(img, spoilerUri, reason);

  const imgEl = $<HTMLImageElement>('img', picEl);
  const imgOverlay = getSpoilerOverlay(img);

  if (!imgEl || imgEl.src.indexOf(spoilerUri) !== -1) return;

  imgEl.srcset = '';
  imgEl.src = spoilerUri;

  imgOverlay.innerHTML = reason;
  imgOverlay.classList.remove('hidden');
}

export function spoilerThumb(img: HTMLDivElement, spoilerUri: string, reason: string) {
  hideThumb(img, spoilerUri, reason);

  switch (window.booru.spoilerType) {
    case 'click':
      img.addEventListener('click', event => {
        if (showThumb(img)) event.preventDefault();
      });
      img.addEventListener('mouseleave', () => hideThumb(img, spoilerUri, reason));
      break;
    case 'hover':
      img.addEventListener('mouseenter', () => showThumb(img));
      img.addEventListener('mouseleave', () => hideThumb(img, spoilerUri, reason));
      break;
    default:
      break;
  }
}

export function spoilerBlock(img: HTMLDivElement, spoilerUri: string, reason: string) {
  const imgFiltered = $<HTMLElement>('.image-filtered', img);
  const imgEl = imgFiltered ? $<HTMLImageElement>('img', imgFiltered) : null;
  if (!imgEl) return;

  const imgReason = getFilterExplanation(img);
  const imageShow = $<HTMLElement>('.image-show', img);

  imgEl.src = spoilerUri;
  imgReason.innerHTML = reason;

  imageShow?.classList.add('hidden');
  if (imgFiltered) imgFiltered.classList.remove('hidden');
}
